package Sub::Throttler::Limit;

use warnings;
use strict;
use utf8;
use feature ':5.10';
use Carp;
our @CARP_NOT = qw( Sub::Throttler );

use version; our $VERSION = qv('0.1.1');    # REMINDER: update Changes

# REMINDER: update dependencies in Build.PL
use Sub::Throttler qw( :plugin );


use constant DEFAULT_KEY    => 'default';


sub new {
    my $class = shift;
    my $self = bless {@_}, ref $class || $class;
    return $self;
}

sub acquire {
    my ($self, $id, $key, $quantity) = @_;
    croak sprintf '%s already acquired %s', $id, $key
        if $self->{acquired}{$id} && exists $self->{acquired}{$id}{$key};
    croak 'quantity must be positive' if $quantity <= 0;

    my $used = $self->{used}{$key} || 0;
    if ($used + $quantity > $self->limit) {
        return;
    }
    $self->{used}{$key} = $used + $quantity;

    $self->{acquired}{$id}{$key} = $quantity;
    return 1;
}

sub apply_to {
    goto &throttle_add;
}

sub apply_to_functions {
    my ($self, @func) = @_;
    my %func = map { $_ => DEFAULT_KEY }
        map {/::/ms ? $_ : caller().q{::}.$_} @func;
    $self->apply_to(sub {
        my ($this, $name) = @_;
        return
            $this   ? undef
          : @func   ? $func{$name}
          :           DEFAULT_KEY
          ;
    });
    return $self;
}

sub apply_to_methods {
    my ($self, $class_or_obj, @func) = @_;
    croak 'method must not contain ::' if grep {/::/ms} @func;
    my %func = map { $_ => DEFAULT_KEY } @func;
    if (1 == @_) {
        $self->apply_to(sub {
            my ($this) = @_;
            return $this ? DEFAULT_KEY : undef;
        });
    } elsif (ref $class_or_obj) {
        $self->apply_to(sub {
            my ($this, $name) = @_;
            return
                !$this || !ref $this || $this != $class_or_obj  ? undef
              : @func                                           ? $func{$name}
              :                                                   DEFAULT_KEY
              ;
        });
    } else {
        $self->apply_to(sub {
            my ($this, $name) = @_;
            my $class = !$this ? q{} : ref $this || $this;
            return
                !$this || $class ne $class_or_obj   ? undef
              : @func                               ? $func{$name}
              :                                       DEFAULT_KEY
              ;
        });
    }
    return $self;
}

sub limit {
    my ($self, $limit) = @_;
    if (1 == @_) {
        return $self->{limit} // 1;
    }
    $self->{limit} = $limit;
    throttle_flush();
    return $self;
}

sub release {
    return _release(@_);
}

sub release_unused {
    return _release(@_);
}

sub used {
    my ($self, $key, $quantity) = @_;
    if (2 == @_) {
        return $self->{used}{$key} || 0;
    }
    $self->{used}{$key} = 0+$quantity;
    throttle_flush();
    return $self;
}

sub _release {
    my ($self, $id) = @_;
    croak sprintf '%s not acquired anything', $id if !$self->{acquired}{$id};

    for my $key (keys %{ $self->{acquired}{$id} }) {
        my $quantity = $self->{acquired}{$id}{$key};
        $self->{used}{$key} -= $quantity;
        # clean up (avoid memory leak in long run with unique keys)
        if (!$self->{used}{$key}) {
            delete $self->{used}{$key};
        }
    }
    delete $self->{acquired}{$id};
    throttle_flush();
    return $self;
}


1; # Magic true value required at end of module
__END__

=encoding utf8

=head1 NAME

Sub::Throttler::Limit - throttle by quantity


=head1 SYNOPSIS

    use Sub::Throttler::Limit;
    
    my $throttle = Sub::Throttler::Limit->new(limit => 5);
    
    $throttle->apply_to_methods(Mojo::UserAgent => qw( get post ));


=head1 DESCRIPTION

This is a plugin for L<Sub::Throttler> providing simple algorithm for
throttling by quantity of used resources.

In a nutshell it's just a hash, with resource names as keys and currently
used resource quantities as values; plus one limit on maximum quantity
applied to any key. Of course, each instance will have own hash/limit.

When you configure it you define which functions/methods it should
throttle, and which resource name(s) and quantity(ies) of that resource(s)
each function/method should acquire to run.

In basic use case you'll use one instance and configure it using
L</"apply_to_functions"> and/or L</"apply_to_methods"> helpers - which
result in any throttled function/method will need C<1> resource named
C<"default"> to run. This way you'll effectively use just one counter,
which will increase when any throttled function/method run and decrease
when it finish, so you will have up to C<limit> simultaneously running
functions/methods (C<limit> is usually set when you call L</"new">).

    my $throttle_tasks = Sub::Throttler::Limit->new(limit => 5);
    $throttle_tasks->apply_to_functions('run_background_task');
    # This code will start 5 background tasks but last two will be
    # put into queue instead of being started. When any of started
    # background tasks will finish first one of queued tasks will be
    # started, etc. Usually you'll need event loop or something else
    # to make this really works, but this has nothing with throttling.
    for (1..7) {
        run_background_task();
    }
    # this function must support throttling
    sub run_background_task { ... }

In advanced use case you may use many counters in one instance (by using
L</"apply_to"> to define different resource names/quantities for different
throttled functions/methods) and have many instances (with different
C<limit>) throttling same or different functions/methods.

    my $throttle_tasks = Sub::Throttler::Limit->new(limit => 5);
    my $throttle_cpu   = Sub::Throttler::Limit->new(limit => 100);
    # allow to simultaneously run up to 5 side_task() plus up to:
    # - 5 small_task() or
    # - 2 normal_task() plus 1 small_task() or
    # - 1 large_task() plus 1 normal_task() or
    # - 1 large_task() plus 2 small_task()
    $throttle_tasks->apply_to(sub {
        my ($this, $name, @param) = @_;
        if ($name eq 'small_task') {
            return 'task', 1;
        } elsif ($name eq 'normal_task') {
            return 'task', 2;
        } elsif ($name eq 'large_task') {
            return 'task', 3;
        } elsif ($name eq 'side_task') {
            return 'side', 1;
        }
        return;
    });
    # and apply extra limitation on amount of simultaneously running
    # side_task() depending on it first parameter (number between 1 and
    # 100 showing how much CPU this side_task() will use)
    $throttle_cpu->apply_to(sub {
        my ($this, $name, @param) = @_;
        if ($name eq 'side_task') {
            return 'default', $param[0];
        }
        return;
    });
    # here is how it will works:
    large_task();   # started ($throttle_tasks 'task' == 3)
    side_task(60);  # started ($throttle_tasks 'side' == 1,
                    #          $throttle_cpu 'default' == 60)
    small_task();   # started ($throttle_tasks 'task' == 4)
    normal_task();  # delayed ($throttle_tasks 'task' + 2 > limit)
    side_task(30);  # started ($throttle_tasks 'side' == 2,
                    #          $throttle_cpu 'default' == 90)
    side_task(30);  # delayed ($throttle_cpu 'default' + 30 > limit)


=head1 EXPORTS

Nothing.


=head1 INTERFACE 

=over

=item new

    my $throttle = Sub::Throttler::Limit->new;
    my $throttle = Sub::Throttler::Limit->new(limit => 42);

Create and return new instance of this algorithm.

Default C<limit> is C<1>.

It won't affect throttling of your functions/methods until you'll call
L</"apply_to_functions"> or L</"apply_to_methods"> or L</"apply_to">.

You don't have to keep returned object alive after you've configured
throttling by calling these apply_to methods (you may need to keep it only
if you'll want to add more throttling later or to remove all throttling
configured on this instance using L<Sub::Throttler/"throttle_del">.

=item limit

    my $limit = $throttle->limit;
    $throttle = $throttle->limit(42);

Get or modify current C<limit>.

=back

=head2 Activate throttle for selected subrouties

=over

=item apply_to_functions

    $throttle = $throttle->apply_to_functions;
    $throttle = $throttle->apply_to_functions('func', 'Some::func2');

When called without params will apply to all functions with throttling
support. When called with list of function names will apply to only these
functions (if function name doesn't contain package name it will use
caller's package for that name).

All affected functions will use C<1> resource named C<"default">.

=item apply_to_methods

    $throttle = $throttle->apply_to_methods;
    $throttle = $throttle->apply_to_methods('Class');
    $throttle = $throttle->apply_to_methods($object);
    $throttle = $throttle->apply_to_methods(Class   => qw( method method2 ));
    $throttle = $throttle->apply_to_methods($object => qw( method method2 ));

When called without params will apply to all methods with throttling
support. When called only with C<'Class'> or C<$object> param will apply
to all methods of that class/object. When given list of methods will apply
only to these methods.

In C<'Class'> case will apply both to Class's methods and methods of any
object of that Class.

All affected methods will use C<1> resource named C<"default">.

=item apply_to

    $throttle = $throttle->apply_to(sub {
        my ($this, $name, @params) = @_;
        if (!$this) {
            # it's a function, $name contains package:
            # $name eq 'main::func'
        }
        elsif (!ref $this) {
            # it's a class method:
            # $this eq 'Class::Name'
            # $name eq 'new'
        }
        else {
            # it's an object method:
            # $this eq $object
            # $name eq 'method'
        }
        return undef;               # do no throttle it
        return 'key';               # throttle it by acquiring 1 resource 'key'
        return ('key',5);           # throttle it by acquiring 5 resources 'key'
        return ['key1','key2'];     # throttle it by atomically acquiring:
                                    #   1 resource 'key1' and 1 resource 'key2'
        return (['k1','k2'],[2,5]); # throttle it by atomically acquiring:
                                    #   2 resources 'k1' and 5 resources 'k2'
    });

This is most complex but also most flexible way to configure throttling -
you can introspect what function/method and with what params was called
and return which and how many resources it should acquire before run.

=back

=head2 Manual resource management

It's unlikely you'll need to manually manage resources, but it's possible
to do if you want this - just be careful because if you acquire and don't
release resource used to throttle your functions/methods they may won't be
run anymore.

=over

=item acquire

    my $is_acquired = $throttle->acquire($id, $key, $quantity);

The throttling engine uses C<Scalar::Util::refaddr($done)> for C<$id>
(large number), so it's safe for you to use either non-numbers as C<$id>
or refaddr() of your own variables.

    $throttle->acquire('reserve', 'default', 3) || die;
    $throttle->acquire('extra reserve', 'default', 1) || die;

Will throw if some C<$key> will be acquired more than once by same C<$id>
or C<$quantity> is non-positive.

=item release

    $throttle = $throttle->release($id);

Release all resources previously acquired by one or more calls to
L</"acquire"> using this C<$id>.

=item release_unused

    $throttle = $throttle->release_unused($id);

Release all resources previously acquired by one or more calls to
L</"acquire"> using this C<$id>.

Treat these resources as unused, to make it possible to reuse them as soon
as possible (this may or may not differ from L</"release"> depending on
plugin/algorithms).

=item used

    my $quantity = $throttle->used($key);
    $throttle->used($key, $quantity);

You can use it to manually save and restore current limits between
different executions of your app, when it makes sense. Consider restoring
limits using L</"acquire">, otherwise it will be harder to release these
resources later.

Changing current quantity is probably very bad idea because if you
decrease current value this may result in negative value after all
currently acquired resource will be released.

=back


=head1 BUGS AND LIMITATIONS

No bugs have been reported.


=head1 SUPPORT

Please report any bugs or feature requests through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Sub-Throttler>.
I will be notified, and then you'll automatically be notified of progress
on your bug as I make changes.

You can also look for information at:

=over

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Sub-Throttler>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Sub-Throttler>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Sub-Throttler>

=item * Search CPAN

L<http://search.cpan.org/dist/Sub-Throttler/>

=back


=head1 AUTHOR

Alex Efros  C<< <powerman@cpan.org> >>


=head1 LICENSE AND COPYRIGHT

Copyright 2014 Alex Efros <powerman@cpan.org>.

This program is distributed under the MIT (X11) License:
L<http://www.opensource.org/licenses/mit-license.php>

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

