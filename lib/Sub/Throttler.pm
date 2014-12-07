package Sub::Throttler;

use warnings;
use strict;
use utf8;
use feature ':5.10';
use Carp;

use version; our $VERSION = qv('0.2.0');    # REMINDER: update Changes

# REMINDER: update dependencies in Build.PL
use Perl6::Export::Attrs;
use Scalar::Util qw( weaken refaddr blessed );


use constant CALLER_SUBROUTINE  => 3;

my (@Throttles, @Tasks, @AsapTasks, %Running);
my $IN_flush = 0;
my $IN_flush_recursion = 0;
my $IN_flush_ignore_recursion = 0;
my $IN_flush_pending = 0;


sub done_cb :Export {
    my ($done, $cb_or_obj_or_class, @p) = @_;
    if (ref $cb_or_obj_or_class eq 'CODE') {
        my $cb = $cb_or_obj_or_class;
        return sub { $done->(); $cb->(@p, @_) };
    }
    elsif (blessed($cb_or_obj_or_class)) {
        my $obj = $cb_or_obj_or_class;
        weaken($obj);
        my $method = shift @p;
        croak 'second param must be $method'
            if !$method || (ref $method && ref $method ne 'CODE');
        return sub { $done->(); $obj && $obj->$method(@p, @_) };
    }
    elsif (defined $cb_or_obj_or_class && !ref $cb_or_obj_or_class) {
        my $class = $cb_or_obj_or_class;
        my $method = shift @p;
        croak 'second param must be $method'
            if !$method || (ref $method && ref $method ne 'CODE');
        return sub { $done->(); $class->$method(@p, @_) };
    }
    else {
        croak 'first param must be $cb or $obj or $class';
    }
}

sub throttle_add :Export {
    my ($throttle, $target) = @_;
    croak 'require 2 params' if 2 != @_;
    croak 'throttle must be an object' if !ref $throttle;
    croak 'target must be CODE' if ref $target ne 'CODE';
    push @Throttles, [$throttle, $target];
    return $throttle;
}

sub throttle_del :Export {
    my ($throttle) = @_;
    @Throttles = grep { $throttle && $_->[0] != $throttle } @Throttles;
    throttle_flush();
    return;
}

sub throttle_flush :Export {
    if ($IN_flush) {
        if (!$IN_flush_ignore_recursion) {
            $IN_flush_recursion = 1;
        }
        return;
    }
    $IN_flush = 1;
    $IN_flush_recursion = 0;
    $IN_flush_ignore_recursion = 0;
    $IN_flush_pending = 0;

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
                my $resources = $target->($this, $name, @params);
                next if !defined $resources;
                die "Sub::Throttler: target returns not a HASHREF: $resources\n"
                    if ref $resources ne 'HASH';
                next if !keys %{$resources};
                my $acquired = 0;
                while (my ($key, $quantity) = each %{$resources}) {
                    die "Sub::Throttler: target returns bad quantity for '$key': $quantity\n"
                        if ref $quantity;
                    if ($throttle->try_acquire($id, $key, $quantity)) {
                        $acquired++;
                    }
                    else {
                        last;
                    }
                }
                if ($acquired == keys %{$resources}) {
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
    return _it(0, 0, @_);
}

sub throttle_it_asap :Export {
    return _it(0, 1, @_);
}

sub throttle_it_sync :Export {
    return _it(1, 0, @_);
}

sub throttle_me :Export {
    return _me(\@Tasks, \@_);
}

sub throttle_me_asap :Export {
    return _me(\@AsapTasks, \@_);
}

sub throttle_me_sync :Export {
    my ($done, $failed);

    my ($this, @params);
    my $func = (caller 1)[CALLER_SUBROUTINE];
    croak 'impossible to throttle anonymous function' if !defined &{$func};
    my ($pkg, $name) = $func =~ /\A(.*)::(.*)\z/ms;
    my $is_method = eval { local $SIG{__DIE__}; $_[0]->isa($pkg) };
    if ($is_method) {
        ($this, @params) = @_;
        $done = Sub::Throttler::__done->new($this.q{->}.$name);
    }
    else {
        ($this, @params) = (q{}, @_);
        $name = $func;
        $done = Sub::Throttler::__done->new($func);
    }

    my @old = ($IN_flush, $IN_flush_ignore_recursion);
    ($IN_flush, $IN_flush_ignore_recursion) = (1, 1);
    my $id = refaddr $done;
ACQUIRE_ALL:
    {
        my %acquired;
        for (@Throttles) {
            my ($throttle, $target) = @{$_};
            my $resources = $target->($this, $name, @params);
            next if !defined $resources;
            die "Sub::Throttler: target returns not a HASHREF: $resources\n"
                if ref $resources ne 'HASH';
            next if !keys %{$resources};
            while (my ($key, $quantity) = each %{$resources}) {
                die "Sub::Throttler: target returns bad quantity for '$key': $quantity\n"
                    if ref $quantity;
                if ($throttle->try_acquire($id, $key, $quantity)) {
                    $acquired{$throttle} = $throttle;
                }
                else {
                    eval { ## no critic (RequireCheckingReturnValueOfEval)
                        local $SIG{__DIE__};
                        $throttle->acquire($id, $key, $quantity);
                        $acquired{$throttle} = $throttle;
                    };
                    $failed = $@;
                    for (values %acquired) {
                        $_->release_unused($id);
                    }
                    if ($failed) {
                        last ACQUIRE_ALL;
                    } else {
                        redo ACQUIRE_ALL;
                    }
                }
            }
        }
        $Running{$id} = [values %acquired];
    }
    ($IN_flush, $IN_flush_ignore_recursion) = @old;
    # while waiting for resources needed for this sync call some resources
    # needed for queued async calls may be released, but in this case
    # throttle_flush() wasn't called because it was blocked, so let's
    # ensure it will be called no late than this sync call will $done->()
    $IN_flush_pending = 1;

    if ($failed) {
        croak $failed;
    } else {
        return $done;
    }
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
    if ($IN_flush_pending) {
        throttle_flush();
    }
    return;
}

sub _it {
    my ($is_sync, $is_asap, $func) = @_;
    croak 'require function name' if !$func || ref $func;
    if ($func !~ /::/ms) {
        $func = caller(1) . q{::} . $func;
    }
    croak 'no such function: '.$func if !defined &{$func};
    my $orig = \&{$func};
    ## no critic
    no warnings 'redefine';
    eval 'sub '.$func.' {
        if (!'.$is_sync.' && @_ && ref $_[-1] eq "CODE") {
            my $done = &throttle_me'.($is_asap ? '_asap' : q{}).' || return;
            my $cb = pop;
            $orig->(@_, done_cb($done, $cb));
            return;
        } elsif (wantarray) {
            my $done = &throttle_me_sync;
            my @res = &$orig;
            $done->();
            return @res;
        } else {
            my $done = &throttle_me_sync;
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
    croak 'impossible to throttle anonymous function' if !defined &{$func};
    my $code = \&{$func};
    my ($pkg, $name) = $func =~ /\A(.*)::(.*)\z/ms;
    my $is_method = eval { local $SIG{__DIE__}; $args->[0]->isa($pkg) };
    if ($is_method) {
        my $self = shift @{$args};
        my $done = Sub::Throttler::__done->new($self.q{->}.$name);
        push @{$queue}, [$done, $name, $self, $code, @{$args}];
        if (ref $self) {
            weaken $queue->[-1][2];
        }
    }
    else {
        my $done = Sub::Throttler::__done->new($func);
        push @{$queue}, [$done, $func, q{}, $code, @{$args}];
    }
    throttle_flush();
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
    use Sub::Throttler::Rate::AnyEvent;
    use Sub::Throttler::Periodic::EV;
    
    # Configure throttling algorithms
    my $throttle_parallel_requests
        = Sub::Throttler::Limit->new(limit => 5);
    my $throttle_request_rate
        = Sub::Throttler::Rate::AnyEvent->new(period => 0.1, limit => 10);
    
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
may require specific event loop (like L<Sub::Throttler::Periodic::EV>).

The L</"SYNOPSIS"> shows basic usage example, but there are a lot of
advanced features: define which and how many resources each
function/method use depending not only on it name but also on it params,
normal and high-priority queues for delayed functions/methods, custom
wrappers with ability to free unused resources, write your own
functions/methods with smart support for throttling, implement own
throttling algorithms, save and restore current limits and used resources
between different executions of your app.

Basic use case: limit rate for downloading urls. Advanced use case: apply
complex limits for using remote API, which depends on how many items you
process (i.e. on some params of API call), use high-priority queue to
ensure login/re-login API call will be executed ASAP before any other
delayed API calls, cancel unused limits in case of failed API call to
avoid needless delay for next API calls, save/restore used resources to
avoid occasional exceeding the quota because of crash/restart of your app.

=head2 ALGORITHMS / PLUGINS

These algorithms are included in this module, but there are may be other
algorithms available as separate modules on CPAN.

L<Sub::Throttler::Limit> implement algorithm to throttle based on quantity
of used resources/limits. For example, it will let you limit an amount of
simultaneous tasks.

L<Sub::Throttler::Rate::AnyEvent> implement algorithm to throttle based on rate
(quantity of used resources/limits per some period of time). For example,
it will let you control maximum calls/sec and burst rate (by choosing
between "1000 calls per 1 second" and "10 calls per 0.01 second" limits).

L<Sub::Throttler::Periodic::EV> is similar to L<Sub::Throttler::Rate::AnyEvent>,
but it treat "period" differently, using absolute wall-clock time instead
of relative time (for ex. if period is set to 1 hour then it begins at
00m00s and ends at 59m59s of every hour).

=head2 HOW THROTTLING WORKS

To be able to throttle some function/method it should support throttling.
This mean it either should be implemented using this module (see
L</"throttle_me">, L</"throttle_me_asap"> and L</"throttle_me_sync">), or
you should replace original function/method with special wrapper. Simple
(but limited) way to do this is use L</"throttle_it">,
L</"throttle_it_asap"> and L</"throttle_it_sync"> helpers.
If simple way doesn't work for you then you can implement
L</"custom wrapper"> yourself.

Next, not all functions/methods with throttling support should be actually
throttled - you should configure which of them and how exactly should be
throttled by using throttling algorithm objects.

Then, when some function/method (which has throttling support and some
limits applied using throttling algorithms) is called, it will
try to acquire some resources (see below) - on success it will be
immediately executed, otherwise it execution will be delayed until these
resources will be available. When it's finished it should explicitly free
used resources (if it was unable to do it work - for example because of
network error - it may cancel resources as unused) - to let some other
(delayed until these resources will be available) function/method runs.

How exactly function/method will be delayed depends on it type:

=over

=item async

Async function/method will be delayed by adding it into queue (normal or
high-priority one) and returning. It will be run later, when resources
needed for it will become available: when another async function/method
(which is already running) will finish and release used resources, or when
some resources will become available automatically as time passes, or if
you reconfigure algorithm objects and increase amount of available
resources, or if you manually release resources which you've manually
acquired before. In most cases your application should use some event loop
to have these events happens.

As side effect, B<you won't get value returned by async function/method>
(if any) because execution of this function/method may be delayed by
adding it into queue instead of running it immediately. In most cases this
isn't a problem because async functions usually return results using
user's callback when done and don't return anything useful when started.

=item sync

Sync function/method will be delayed by calling sleep() if some resources
it needs isn't available yet. Of course, this will work only with
algorithms which automatically release some resources as time passes
(like L<Sub::Throttler::Rate::AnyEvent> or L<Sub::Throttler::Periodic::EV>).
In all other cases - used algorithm doesn't release resources with time
(like L<Sub::Throttler::Limit>) or needed amount of resources is over
algorithm's maximal limit - it doesn't make sense to sleep() and thus
exception will be thrown (such exception indicate bug in your code and
should never happens otherwise).

=back

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
            return { default=>1 };  # require 1 resource named "default"
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
            return { some=>2, other=>10 };
        }
        return;                     # do not throttle other functions/methods
    });

It's allowed to "apply" same C<$throttle> instance to same
functions/methods more than once if you won't return B<same resource name>
more than once for same function/method.

How exactly these "resources" will be acquired and released depends on
used algorithm.

=head3 PRIORITY / QUEUES

There are two separate queues for delayed async functions/methods: normal and
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

Same as L</"throttle_it"> but use high-priority "asap" queue for async
function/method calls.

=item throttle_it_sync

    my $orig_func = throttle_it_sync('func');
    my $orig_func = throttle_it_sync('Some::func2');

Same as L</"throttle_it"> but doesn't try to handle given function/method
as async even if it's called with CODEREF in last parameter.

=back

=head3 custom wrapper

If you want to call C<< $done->() >> after async function/method callback
or before sync function/method will be actually called
or want to cancel unused resources in some cases by calling C<< $done->(0) >>
you should implement custom wrapper instead of using L</"throttle_it">,
L</"throttle_it_asap"> or L</"throttle_it_sync"> helpers.

Throttling anonymous function is not supported, that's why you need to use
string C<eval> instead of C<< *Some::func = sub { 'wrapper' }; >> here
(actually, you can avoid string eval using L<Sub::Util/"set_subname">).

    # Example wrapper for sync function which called in scalar context and
    # return false when it failed to do it work (we want to cancel
    # unused resources in this case).
    my $orig_func = \&Some::func;
    eval <<'EOW';
    no warnings 'redefine';
    sub Some::func {
        my $done = &throttle_me_sync;
        my $result = $orig_func->(@_);
        if ($result) {
            $done->();
        } else {
            $done->(0);
        }
        return $result;
    }
    EOW
    
    # Example wrapper for sync function/method which can be called in any
    # context, don't affect call stack and release resources when start.
    # Also let's use Sub::Util to avoid string eval.
    use Sub::Util qw( set_subname );
    my $orig_sub = \&Some::sub;
    no warnings 'redefine';
    *Some::sub = set_subname 'Some::sub', sub {
        my $done = &throttle_me_sync;
        $done->();
        goto &$orig_sub;
    };
    
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
        return;
    }
    EOW

=head2 Writing functions/methods with support for throttling

To have maximum control over some function/method throttling you should
write that function yourself (in some cases it's enough to write a
L</"custom wrapper"> for existing function/method). This will let you
control when exactly it should release used resources or cancel unused
resources to let next delayed function/method run as soon as possible.

=over

=item throttle_me

    sub async_func {
        my $done = &throttle_me || return;
        my (@params) = @_;
        if ('unable to do the work') {
            $done->(0);
            return;
        }
        ...
        $done->();
        return;
    }
    sub async_method {
        my $done = &throttle_me || return;
        my ($self, @params) = @_;
        if ('unable to do the work') {
            $done->(0);
            return;
        }
        ...
        $done->();
        return;
    }

Support only async function/method, which can't return anything to caller
(because it call may be delayed because of throttling). When this
function/method will be executed it won't get anything useful from
caller() or wantarray() because it will be called from internals of
this module.

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

This will make this async function/method use high-priority "asap" queue
instead of normal queue.

=item throttle_me_sync

Similar to L</"throttle_me"> but for sync function/method:

        my $done = &throttle_me_sync;

Delaying sync function/method is implemented using sleep(), so caller()
and wantarray() will work as expected, so only difference from usual
function/method is needs to call C<&throttle_me_sync> on start and then
later release resources.

=item done_cb

    my $cb = done_cb($done, sub {
        my (@params) = @_;
        ...
    });

    my $cb = done_cb($done, sub {
        my ($extra1, $extra2, @params) = @_;
        ...
    }, $extra1, $extra2);

    my $cb = done_cb($done, $class_or_object, 'method');
    sub Class::Of::That::Object::method {
        my ($self, @params) = @_;
        ...
    }

    my $cb = done_cb($done, $class_or_object, 'method', $extra1, $extra2);
    sub Class::Of::That::Object::method {
        my ($self, $extra1, $extra2, @params) = @_;
        ...
    }

This is a simple helper function used to make sure you won't forget to
call C<< $done->() >> in your async function/method with throttling support.

First parameter must be C< $done > callback, then either callback function
or object (or class name) and name of it method, and then optionally any
extra params for that callback function/object's method.

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

It's recommended to inherit your algorithm from L<Sub::Throttler::algo>.

Each plugin must provide these methods (they'll be called by throttling
engine):

    sub acquire {
        my ($self, $id, $key, $quantity) = @_;
        if ('resource temporary unavailable') {
            # wait for resource (don't use external event loop or
            # anything else which may call user's code/callbacks!)
            sleep(...);
        }
        # acquire $quantity of resources named $key for
        # function/method identified by $id
        if ('failed to acquire') {
            croak "$self: unable to acquire $quantity of resource '$key'";
        }
        return $self;
    }
    sub try_acquire {
        my ($self, $id, $key, $quantity) = @_;
        # try to acquire $quantity of resources named $key for
        # function/method identified by $id
        if ('failed to acquire') {
            return;
        }
        return 1;
    }
    sub release {
        my ($self, $id) = @_;
        # release resources previously acquired for $id
        if ('amount of available resources was increased') {
            throttle_flush();
        }
        return $self;
    }
    sub release_unused {
        my ($self, $id) = @_;
        # cancel unused resources previously acquired for $id
        if ('amount of available resources was increased') {
            throttle_flush();
        }
        return $self;
    }

While trying to find out is there are enough resources to run some delayed
function/method throttling engine may call C<release_unused()> immediately
after successful C<try_acquire()> - if it turns out some other resource
needed for same function/method isn't available.

Also, usually plugins should provide few more methods, which isn't used by
throttling engine (so they're optional in some sense), but usually they
needed for application which uses that algorithm:

    sub new {
        my ($class, %options) = @_;
        # create new algorithm object
        return $self;
    }
    sub load {
        my ($class, $state) = @_;
        # create new algorithm object using previous state from $state
        # (which usually include both object's configuration like {limit}
        # plus information about currently acquired resources)
        return $self;
    }
    sub save {
        my ($self) = @_;
        # generate and return perl structure describing current
        # object's configuration and acquired resources
        return $state;
    }

=over

=item throttle_add

    throttle_add($throttle_plugin, sub {
        my ($this, $name, @params) = @_;
        # $this is undef or a class name or an object
        # $name is a function or method name
        # @params is function/method params
        ...
        return;                         # OR
        return {key1=>$quantity1, ...};
    });

This function usually used to implement helper methods in algorithm like
L<Sub::Throttler::algo/"apply_to">,
L<Sub::Throttler::algo/"apply_to_functions">,
L<Sub::Throttler::algo/"apply_to_methods">. But if algorithm doesn't
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

