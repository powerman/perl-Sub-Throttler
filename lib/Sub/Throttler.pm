package Sub::Throttler;

use warnings;
use strict;
use utf8;
use feature ':5.10';
use Carp;

use version; our $VERSION = qv('0.1.1');    # REMINDER: update Changes

# REMINDER: update dependencies in Build.PL
use Perl6::Export::Attrs;
use Scalar::Util qw( weaken refaddr );


use constant CALLER_SUBROUTINE  => 3;

my (@Throttles, @Tasks, @AsapTasks, %Running);
# These $IN_flush* vars should be 'state' vars inside throttle_flush(),
# but they're here to make it possible to use _reset() in tests.
my $IN_flush = 0;
my $IN_flush_recursion = 0;
my $IN_flush_ignore_recursion = 0;


sub done_cb :Export {
    my ($done, $cb_or_obj, @p) = @_;
    croak 'require ($obj,$method) or ($cb)' if !ref $cb_or_obj;
    my $cb = ref $cb_or_obj ne 'CODE' ? _weak_cb($cb_or_obj, @p) : sub { $cb_or_obj->(@p, @_) };
    return sub { $done->(); $cb->(@_) };
}

sub throttle_add :Export(:plugin) {
    my ($throttle, $target) = @_;
    croak 'require 2 params' if 2 != @_;
    croak 'throttle must be an object' if !ref $throttle;
    croak 'target must be CODE' if ref $target ne 'CODE';
    push @Throttles, [$throttle, $target];
    return $throttle;
}

sub throttle_del :Export(:plugin) {
    my ($throttle) = @_;
    @Throttles = grep { $throttle && $_->[0] != $throttle } @Throttles;
    throttle_flush();
    return;
}

sub throttle_flush :Export(:plugin) { ## no critic (ProhibitExcessComplexity)
    if ($IN_flush) {
        if (!$IN_flush_ignore_recursion) {
            $IN_flush_recursion = 1;
        }
        return;
    }
    $IN_flush = 1;
    $IN_flush_recursion = 0;
    $IN_flush_ignore_recursion = 0;

    for my $tasks (\@AsapTasks, \@Tasks) {
        my @tasks = @{$tasks};
        @{$tasks} = ();
        my @delayed;
TASK:
        for my $task (@tasks) {
            my ($done, $name, $this, $code, @params) = @{$task};
            my $id = refaddr $done;
            if (!defined $this) {
                $done->();  # release $done
                next;
            }
            my %acquired;
            for (@Throttles) {
                my ($throttle, $target) = @{$_};
                my ($key, $quantity) = $target->($this, $name, @params);
                next if !defined $key;
                if (!ref $key) {
                    $key = [ $key ];
                }
                die "Sub::Throttler: target returns bad key: $key\n" if ref $key ne 'ARRAY';
                next if !@{$key};
                $quantity //= 1;
                if (!ref $quantity) {
                    $quantity = [ ($quantity) x @{$key} ];
                }
                die "Sub::Throttler: target returns bad quantity: $quantity\n" if ref $quantity ne 'ARRAY';
                die "Sub::Throttler: target returns unmatched keys and quantities: [@{$key}] [@{$quantity}]\n"
                    if @{$key} != @{$quantity};
                my $acquired = 0;
                for my $i (0 .. $#{$key}) {
                    if ($throttle->acquire($id, $key->[$i], $quantity->[$i])) {
                        $acquired++;
                    }
                    else {
                        last;
                    }
                }
                if ($acquired == @{$key}) {
                    $acquired{$throttle} = $throttle;
                }
                else {
                    $IN_flush_ignore_recursion = 1;
                    if ($acquired) {
                        $throttle->release_unused($id);
                    }
                    for (values %acquired) {
                        $_->release_unused($id);
                    }
                    $IN_flush_ignore_recursion = 0;
                    push @delayed, $task;
                    next TASK;
                }
            }
            $Running{$id} = [values %acquired];
            _run_task($this, $code, $done, @params);
        }
        @{$tasks} = (@delayed, @{$tasks}); # while _run_task() new tasks may be added
    }

    $IN_flush = 0;
    goto &throttle_flush if $IN_flush_recursion;
    return;
}

sub throttle_it :Export {
    return _it(0, @_);
}

sub throttle_it_asap :Export {
    return _it(1, @_);
}

sub throttle_me :Export {
    return _me(\@Tasks, \@_);
}

sub throttle_me_asap :Export {
    return _me(\@AsapTasks, \@_);
}

sub _done { ## no critic (ProhibitUnusedPrivateSubroutines)
    my ($id, $is_used) = @_;
    $is_used ||= 1 == @_;
    for my $throttle (@{ delete $Running{$id} // [] }) {
        if ($is_used) {
            $throttle->release($id);
        } else {
            $throttle->release_unused($id);
        }
    }
    return;
}

sub _it {
    my ($is_asap, $func) = @_;
    croak 'require function name' if !$func || ref $func;
    if ($func !~ /::/ms) {
        $func = caller(1) . q{::} . $func;
    }
    croak 'no such function: '.$func if !defined &{$func};
    my $orig = \&{$func};
    ## no critic
    no warnings 'redefine';
    eval 'sub '.$func.' {
        my $done = &throttle_me'.($is_asap ? '_asap' : q{}).' || return;
        if (@_ && ref $_[-1] eq "CODE") {
            my $cb = pop;
            return $orig->(@_, done_cb($done, $cb));
        } elsif (wantarray) {
            my @res = &$orig;
            $done->();
            return @res;
        } else {
            my $res = &$orig;
            $done->();
            return $res;
        }
    }; 1' or die $@;
    return $orig;
}

sub _me {
    my ($queue, $args) = @_;
    for (0, 1) {
        if (ref $args->[$_] eq 'Sub::Throttler::__done') {
            return splice @{$args}, $_, 1;
        }
    }
    my $func = (caller 2)[CALLER_SUBROUTINE];
    croak 'impossible to throttle anonymous function' if $func =~ /::__ANON__\z/ms;
    my $code = \&{$func};
    my ($pkg, $name) = $func =~ /\A(.*)::(.*)\z/ms;
    my $is_method = defined $args->[0] && (ref $args->[0] || $args->[0]) eq $pkg;
    ## no critic (ProhibitProlongedStrictureOverride ProhibitNoWarnings)
    no strict 'refs';
    no warnings 'redefine';
    *{$func} = $is_method ? sub {
        my ($self, @params) = @_;
        my $done = Sub::Throttler::__done->new($self.q{->}.$name);
        push @{$queue}, [$done, $name, $self, $code, @params];
        weaken $queue->[-1][2];
        throttle_flush();
        return;
    } : sub {
        my @params = @_;
        my $done = Sub::Throttler::__done->new($func);
        push @{$queue}, [$done, $func, q{}, $code, @params];
        throttle_flush();
        return;
    };
    $func->(@{$args});
    return;
}

# should be used only from tests
sub _reset { ## no critic (ProhibitUnusedPrivateSubroutines)
    $IN_flush = 0;
    $IN_flush_recursion = 0;
    $IN_flush_ignore_recursion = 0;
    @Throttles = @Tasks = @AsapTasks = %Running = ();
    return;
}

sub _run_task {
    my ($this, $code, $done, @params) = @_;
    no strict 'refs';
    if ($this) {
        $this->$code($done, @params);
    } else {
        $code->($done, @params);
    }
    return;
}

sub _weak_cb {
    my ($this, $method, @p) = @_;
    weaken $this;
    return sub { $this && $this->$method(@p, @_) };
}


package Sub::Throttler::__done;    ## no critic (ProhibitMultiplePackages)
use Carp;

use Scalar::Util qw( refaddr );

my (%Check, %Name);

sub new {
    my (undef, $name) = @_;
    my $id;
    my $done = bless sub {
        if ($Check{$id}) {
            croak "Sub::Throttler: $name: \$done->() already called";
        }
        $Check{$id}=1;
        Sub::Throttler::_done($id, @_); ## no critic(ProtectPrivateSubs)
    }, __PACKAGE__;
    $id = refaddr $done;
    $Name{$id} = $name;
    return $done;
}

sub DESTROY {
    my $done = shift;
    my $id   = refaddr $done;
    my $name = delete $Name{$id};
    if (!delete $Check{$id}) {
        carp "Sub::Throttler: $name: \$done->() was not called";
    }
    return;
}


1; # Magic true value required at end of module
__END__

=encoding utf8

=head1 NAME

Sub::Throttler - Rate limit sync and async function calls


=head1 SYNOPSIS

    # Load throttling engine
    use Sub::Throttler qw( throttle_it );
    
    # Enable throttling for existing sync/async functions/methods
    throttle_it('Mojo::UserAgent::get');
    throttle_it('Mojo::UserAgent::post');
    
    # Load throttling algorithms
    use Sub::Throttler::Limit;
    use Sub::Throttler::Rate::EV;
    
    # Configure throttling algorithms
    my $throttle_parallel_requests
        = Sub::Throttler::Limit->new(limit => 5);
    my $throttle_request_rate
        = Sub::Throttler::Rate::EV->new(period => 0.1, limit => 10);
    
    # Apply configured limits to selected functions/methods with
    # throttling support
    $throttle_parallel_requests->apply_to_methods(Mojo::UserAgent => qw( get ));
    $throttle_request_rate->apply_to_methods(Mojo::UserAgent => qw( get post ));


=head1 DESCRIPTION

This module provide sophisticated throttling framework which let you delay
execution of any sync and async functions/methods based on any rules you
need.

You can use core features of this framework with usual sync application or
with application based on any event loop, but some throttling algorithms
may require specific event loop (like L<Sub::Throttler::Rate::EV>).

The L</"SYNOPSIS"> shows basic usage example, but there are a lot of
advanced features: define which and how many resources each
function/method use depending not only on it name but also on it params,
normal and high-priority queues for throttled functions/methods, custom
wrappers with ability to free unused limits, write your own
functions/methods with smart support for throttling, implement own
throttling algorithms, save and restore current limits between different
executions of your app.

Basic use case: limit rate for downloading urls. Advanced use case: apply
complex limits for using remote API, which depends on how many items you
process (i.e. on some params of API call), use high-priority queue to
ensure login/re-login API call will be executed ASAP before any other
delayed API calls, cancel unused limits in case of failed API call to
avoid needless delay for next API calls, save/restore used limits to avoid
occasional exceeding the quota because of crash/restart of your app.

=head2 ALGORITHMS / PLUGINS

L<Sub::Throttler::Limit> implement algorithm to throttle based on quantity
of used resources/limits. For example, it will let you limit an amount of
simultaneous tasks. Also it's good base class for your own algorithms.

L<Sub::Throttler::Rate::EV> implement algorithm to throttle based on rate
(quantity of used resources/limits per some period of time). For example,
it will let you control maximum calls/sec and burst rate (by choosing
between "1000 calls per 1 second" and "10 calls per 0.01 second" limits).

=head2 HOW THROTTLING WORKS

To be able to throttle some function/method it should support throttling.
This mean it either should be implemented using this module (see
L</"throttle_me"> and L</"throttle_me_asap">), or you should replace
original function/method with special wrapper. Simple (but limited) way to
do this is use L</"throttle_it"> and L</"throttle_it_asap"> helpers.
If simple way doesn't work for you then you can implement
L</"custom wrapper"> yourself.

Next, not all functions/methods with throttling support will be actually
throttled - you should configure which of them and how exactly should be
throttled by using throttling algorithm objects.

Then, when some function/method with throttling support is called, it will
try to acquire some resources (see below) - on success it will be
immediately executed, otherwise it execution will be delayed until these
resources will be available. When it's finished it should explicitly free
used resources (if it was unable to do it work - for example because of
network error - it may cancel resources as unused) - to let some other
(delayed until these resources will be available) function/method runs.

=head3 HOW TO CONTROL LIMITS / RESOURCES

When you configure throttling for some function/method you define which
"resources" and how much of them it needs to run. The "resource" is just
any string, and in simple case all throttled functions/methods will use
same string (say, C<"default">) and same quantity of this "resource": C<1>.

    # this algorithm allow using up to 5 "resources" of same name
    $throttle = Sub::Throttler::Limit->new(limit => 5);
    
    # this is same:
    $throttle->apply_to_functions('Package::func');
    # as this:
    $throttle->apply_to(sub {
        my ($this, $name, @params) = @_;
        if (!$this && $name eq 'Package::func') {
            return 'default', 1;    # require 1 resource named "default"
        }
        return;                     # do not throttle other functions/methods
    });

But in complex cases you can (based on name of function or class name or
exact object and method name, and their parameters) define several
"resources" with different quantities of each.

    $throttle->apply_to(sub {
        my ($this, $name, @params) = @_;
        if (ref $this && $this eq $target_object && $name eq 'method') {
            # require 2 "some" and 10 "other" resources
            return ['some','other'], [2,10];
        }
        return;                     # do not throttle other functions/methods
    });

It's allowed to "apply" same C<$throttle> instance to same
functions/methods more than once if you won't require B<same> resource
name more than once for same function/method.

How exactly these "resources" will be acquired and released depends on
used algorithm.

=head3 PRIORITY / QUEUES

There are two separate queues for delayed functions/methods: normal and
high-priority "asap" queue. Functions/methods in "asap" queue will be
executed before any (even delayed before them) function/method in normal
queue which require B<same resources> to run. But if there are not enough
resources to run function/method from high-priority queue and enough to
run from normal queue - function/method from normal queue will be run.

Which function/method will use normal and which "asap" queue is defined by
that function/method (or it wrapper) implementation.

Delayed methods in queue use weak references to their objects, so these
objects doesn't kept alive only because of these delayed method calls.
If these objects will be destroyed then their delayed methods will be
silently removed from queue.


=head1 EXPORTS

Nothing by default, but all documented functions can be explicitly imported.

Use tag C<:ALL> to import all of them.

If you developing plugin for this module you can use tag C<:plugin> to
import C<throttle_add>, C<throttle_del> and C<throttle_flush>.


=head1 INTERFACE 

=head2 Enable throttling for existing functions/methods

=over

=item throttle_it

    my $orig_func = throttle_it('func');
    my $orig_func = throttle_it('Some::func2');

This helper is able to replace with wrapper either sync function/method
or async function/method which receive B<callback in last parameter>.

That wrapper will call C<< $done->() >> (release used resources, see
L</"throttle_me"> for details about it) after sync function/method returns
or just before callback of async function/method will be called.

If given function name without package it will look for that function in
caller's package.

Return reference to original function or throws if given function is not
exists.

=item throttle_it_asap

    my $orig_func = throttle_it_asap('func');
    my $orig_func = throttle_it_asap('Some::func2');

Same as L</"throttle_it"> but use high-priority "asap" queue.

=back

=head3 custom wrapper

If you want to call C<< $done->() >> after async function/method callback
or want to cancel unused resources in some cases by calling C<< $done->(0) >>
you should implement custom wrapper instead of using L</"throttle_it"> or
L</"throttle_it_asap"> helpers.

Throttling anonymous function is not supported, that's why you need to use
string C<eval> instead of C<< *Some::func = sub { 'wrapper' }; >> here.

    # Example wrapper for sync function which called in scalar context and
    # return false when it failed to do it work (we want to cancel
    # unused resources in this case).
    my $orig_func = \&Some::func;
    eval <<'EOW';
    no warnings 'redefine';
    sub Some::func {
        my $done = &throttle_me || return;
        my $result = $orig_func->(@_);
        if ($result) {
            $done->();
        } else {
            $done->(0);
        }
        return $result;
    }
    EOW
    
    # Example wrapper for async method which receive callback in first
    # parameter and call it with error message when it failed to do it
    # work (we want to cancel unused resources in this case); we also want
    # to call $done->() after callback and use "asap" queue.
    my $orig_method = \&Class::method;
    eval <<'EOW';
    no warnings 'redefine';
    sub Class::method {
        my $done = &throttle_me_asap || return;
        my $self = shift;
        my $orig_cb = shift;
        my $cb = sub {
            my ($error) = @_;
            $orig_cb->(@_);
            if ($error) {
                $done->(0);
            } else {
                $done->();
            }
        };
        $self->$orig_method($cb, @_);
    }
    EOW

=head2 Writing functions/methods with support for throttling

To have maximum control over some function/method throttling you should
write that function yourself (in some cases it's enough to write
L</"custom wrapper"> for existing function/method). This will let you
control when exactly it should release used resources or cancel unused
resources to let next delayed function/method run as soon as possible.

=over

=item throttle_me

    sub func {
        my $done = &throttle_me || return;
        my (@params) = @_;
        if ('unable to do the work') {
            $done->(0);
            return;
        }
        ...
        $done->();
    }
    sub method {
        my $done = &throttle_me || return;
        my ($self, @params) = @_;
        if ('unable to do the work') {
            $done->(0);
            return;
        }
        ...
        $done->();
    }

You should use it exactly as it shown in these examples: it should be
called using form C<&throttle_me> because it needs to modify your
function/method's C<@_>.

If your function/method should be delayed because of throttling it will
return false, and you should interrupt your function/method. Otherwise
it'll acquire "resources" needed to run your function/method and return
callback which you should call later to release these resources.

If your function/method has done it work (and thus "used" these resources)
C<$done> should be called without parameters C<< $done->() >> or with one
true param C<< $done->(1) >>; if it hasn't done it work (and thus "not
used" these resources) it's better to call it with one false param
C<< $done->(0) >> to cancel these unused resources and give a chance for
another function/method to reuse them.

If you forget to call C<$done> - you'll get a warning (and chances are
you'll soon run out of resources because of this and new throttled
functions/methods won't be run anymore), if you call it more than once -
exception will be thrown.

Anonymous functions are not supported.

=item throttle_me_asap

Same as L</"throttle_me"> except use C<&throttle_me_asap>:

        my $done = &throttle_me_asap || return;

This will make this function/method use high-priority "asap" queue instead
of normal queue.

=item done_cb

    my $cb = done_cb($done, sub {
        my (@params) = @_;
        ...
    });

    my $cb = done_cb($done, sub {
        my ($extra1, $extra2, @params) = @_;
        ...
    }, $extra1, $extra2);

    my $cb = done_cb($done, $object, 'method');
    sub Class::Of::That::Object::method {
        my ($self, @params) = @_;
        ...
    }

    my $cb = done_cb($done, $object, 'method', $extra1, $extra2);
    sub Class::Of::That::Object::method {
        my ($self, $extra1, $extra2, @params) = @_;
        ...
    }

This is a simple helper function used to make sure you won't forget to
call C<< $done->() >> in your async function/method with throttling support.

First parameter must be C< $done > callback, then either callback function
or object and name of it method, and then optionally any extra params for
that callback function/object's method.

Returns callback, which when called will first call C<< $done->() >> and then
given callback function or object's method with any extra params (if any)
followed by it own params.

Example:

    # use this:
    sub download {
        my $done = &throttle_me || return;
        my ($url) = @_;
        $ua->get($url, done_cb($done, sub {
            my ($ua, $tx) = @_;
            ...
        }));
    }
    # instead of this:
    sub download {
        my $done = &throttle_me || return;
        my ($url) = @_;
        $ua->get($url, sub {
            my ($ua, $tx) = @_;
            $done->();
            ...
        });
    }

=back

=head2 Implementing throttle algorithms/plugins

It's recommended to inherit your algorithm from L<Sub::Throttler::Limit>.

Each plugin must provide these methods (they'll be called by throttling
engine):

    sub acquire {
        my ($self, $id, $key, $quantity) = @_;
        # try to acquire $quantity of resources named $key for
        # function/method identified by $id
        if ('failed to acquire') {
            return;
        }
        return 1;   # resource acquired
    }
    sub release {
        my ($self, $id) = @_;
        # release resources previously acquired for $id
        if ('some resources was freed') {
            throttle_flush();
        }
    }
    sub release_unused {
        my ($self, $id) = @_;
        # cancel unused resources previously acquired for $id
        if ('some resources was freed') {
            throttle_flush();
        }
    }

While trying to find out is there are enough resources to run some delayed
function/method throttling engine may call C<release_unused()> immediately
after successful C<acquire()> - if it turns out some other resource needed
for same function/method isn't available.

=over

=item throttle_add

    throttle_add($throttle_plugin, sub {
        my ($this, $name, @params) = @_;
        # $this is undef or a class name or an object
        # $name is a function or method name
        # @params is function/method params
        ...
        return undef;                   # OR
        return $key;                    # OR
        return ($key,$quantity);        # OR
        return \@keys;                  # OR
        return (\@keys,\@quantities);
    });

This function usually used to implement helper methods in algorithm like
L<Sub::Throttler::Limit/"apply_to">,
L<Sub::Throttler::Limit/"apply_to_functions">,
L<Sub::Throttler::Limit/"apply_to_methods">. But if algorithm doesn't
implement such helpers it may be used directly by user to apply some
algorithm instance to selected functions/methods.

=item throttle_del

    throttle_del();
    throttle_del($throttle_plugin);

Undo previous L</"throttle_add"> calls with C<$throttle_plugin> in first
param or all of them if given no param. This is rarely useful, usually you
setup throttling when your app initializes and then doesn't change it.

=item throttle_flush

    throttle_flush();

Algorithm B<must> call it each time quantity of some resources increases
(so there is a chance one of delayed functions/methods can be run now).

=back


=head1 BUGS AND LIMITATIONS

No bugs have been reported.

Throttling anonymous functions is not supported.


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

