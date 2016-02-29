[![Build Status](https://travis-ci.org/powerman/perl-Sub-Throttler.svg?branch=master)](https://travis-ci.org/powerman/perl-Sub-Throttler)
[![Coverage Status](https://coveralls.io/repos/powerman/perl-Sub-Throttler/badge.svg?branch=master)](https://coveralls.io/r/powerman/perl-Sub-Throttler?branch=master)

# NAME

Sub::Throttler - Rate limit sync and async function calls

# VERSION

This document describes Sub::Throttler version v0.2.10

# SYNOPSIS

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

# DESCRIPTION

This module provide sophisticated throttling framework which let you delay
execution of any sync and async functions/methods based on any rules you
need.

You can use core features of this framework with usual sync application or
with application based on any event loop, but some throttling algorithms
may require specific event loop (like [Sub::Throttler::Periodic::EV](https://metacpan.org/pod/Sub::Throttler::Periodic::EV)).

The ["SYNOPSIS"](#synopsis) shows basic usage example, but there are a lot of
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

## ALGORITHMS / PLUGINS

These algorithms are included in this module, but there are may be other
algorithms available as separate modules on CPAN.

[Sub::Throttler::Limit](https://metacpan.org/pod/Sub::Throttler::Limit) implement algorithm to throttle based on quantity
of used resources/limits. For example, it will let you limit an amount of
simultaneous tasks.

[Sub::Throttler::Rate::AnyEvent](https://metacpan.org/pod/Sub::Throttler::Rate::AnyEvent) implement algorithm to throttle based on rate
(quantity of used resources/limits per some period of time). For example,
it will let you control maximum calls/sec and burst rate (by choosing
between "1000 calls per 1 second" and "10 calls per 0.01 second" limits).

[Sub::Throttler::Periodic::EV](https://metacpan.org/pod/Sub::Throttler::Periodic::EV) is similar to [Sub::Throttler::Rate::AnyEvent](https://metacpan.org/pod/Sub::Throttler::Rate::AnyEvent),
but it treat "period" differently, using absolute wall-clock time instead
of relative time (for ex. if period is set to 1 hour then it begins at
00m00s and ends at 59m59s of every hour).

## HOW THROTTLING WORKS

To be able to throttle some function/method it should support throttling.
This mean it either should be implemented using this module (see
["throttle\_me"](#throttle_me), ["throttle\_me\_asap"](#throttle_me_asap) and ["throttle\_me\_sync"](#throttle_me_sync)), or
you should replace original function/method with special wrapper. Simple
(but limited) way to do this is use ["throttle\_it"](#throttle_it),
["throttle\_it\_asap"](#throttle_it_asap) and ["throttle\_it\_sync"](#throttle_it_sync) helpers.
If simple way doesn't work for you then you can implement
["custom wrapper"](#custom-wrapper) yourself.

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

- async

    Async function/method will be delayed by adding it into queue (normal or
    high-priority one) and returning. It will be run later, when resources
    needed for it will become available: when another async function/method
    (which is already running) will finish and release used resources, or when
    some resources will become available automatically as time passes, or if
    you reconfigure algorithm objects and increase amount of available
    resources, or if you manually release resources which you've manually
    acquired before. In most cases your application should use some event loop
    to have these events happens.

    As side effect, **you won't get value returned by async function/method**
    (if any) because execution of this function/method may be delayed by
    adding it into queue instead of running it immediately. In most cases this
    isn't a problem because async functions usually return results using
    user's callback when done and don't return anything useful when started.

- sync

    Sync function/method will be delayed by calling sleep() if some resources
    it needs isn't available yet. Of course, this will work only with
    algorithms which automatically release some resources as time passes
    (like [Sub::Throttler::Rate::AnyEvent](https://metacpan.org/pod/Sub::Throttler::Rate::AnyEvent) or [Sub::Throttler::Periodic::EV](https://metacpan.org/pod/Sub::Throttler::Periodic::EV)).
    In all other cases - used algorithm doesn't release resources with time
    (like [Sub::Throttler::Limit](https://metacpan.org/pod/Sub::Throttler::Limit)) or needed amount of resources is over
    algorithm's maximal limit - it doesn't make sense to sleep() and thus
    exception will be thrown (such exception indicate bug in your code and
    should never happens otherwise).

### HOW TO CONTROL LIMITS / RESOURCES

When you configure throttling for some function/method you define which
"resources" and how much of them it needs to run. The "resource" is just
any string, and in simple case all throttled functions/methods will use
same string (say, `"default"`) and same quantity of this "resource": `1`.

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

It's allowed to "apply" same `$throttle` instance to same
functions/methods more than once if you won't return **same resource name**
more than once for same function/method.

How exactly these "resources" will be acquired and released depends on
used algorithm.

### PRIORITY / QUEUES

There are two separate queues for delayed async functions/methods: normal and
high-priority "asap" queue. Functions/methods in "asap" queue will be
executed before any (even delayed before them) function/method in normal
queue which require **same resources** to run. But if there are not enough
resources to run function/method from high-priority queue and enough to
run from normal queue - function/method from normal queue will be run.

Which function/method will use normal and which "asap" queue is defined by
that function/method (or it wrapper) implementation.

Delayed methods in queue use weak references to their objects, so these
objects doesn't kept alive only because of these delayed method calls.
If these objects will be destroyed then their delayed methods will be
silently removed from queue.

# EXPORTS

Nothing by default, but all documented functions can be explicitly imported.

Use tag `:ALL` to import all of them.

# INTERFACE

## Enable throttling for existing functions/methods

### throttle\_it

    my $orig_func = throttle_it('func');
    my $orig_func = throttle_it('Some::func2');

This helper is able to replace with wrapper either sync function/method
or async function/method which receive **callback in last parameter**.

That wrapper will call `$done->()` (release used resources, see
["throttle\_me"](#throttle_me) for details about it) after sync function/method returns
or just before callback of async function/method will be called.

If given function name without package it will look for that function in
caller's package.

Return reference to original function or throws if given function is not
exists.

### throttle\_it\_asap

    my $orig_func = throttle_it_asap('func');
    my $orig_func = throttle_it_asap('Some::func2');

Same as ["throttle\_it"](#throttle_it) but use high-priority "asap" queue for async
function/method calls.

### throttle\_it\_sync

    my $orig_func = throttle_it_sync('func');
    my $orig_func = throttle_it_sync('Some::func2');

Same as ["throttle\_it"](#throttle_it) but doesn't try to handle given function/method
as async even if it's called with CODEREF in last parameter.

### Custom Wrapper

If you want to call `$done->()` after async function/method callback
or before sync function/method will be actually called
or want to cancel unused resources in some cases by calling `$done->(0)`
you should implement custom wrapper instead of using ["throttle\_it"](#throttle_it),
["throttle\_it\_asap"](#throttle_it_asap) or ["throttle\_it\_sync"](#throttle_it_sync) helpers.

Throttling anonymous function is not supported, that's why you need to use
string `eval` instead of `*Some::func = sub { 'wrapper' };` here
(actually, you can avoid string eval using ["set\_subname" in Sub::Util](https://metacpan.org/pod/Sub::Util#set_subname)).

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
    use Sub::Util 1.40 qw( set_subname );
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

## Writing functions/methods with support for throttling

To have maximum control over some function/method throttling you should
write that function yourself (in some cases it's enough to write a
["custom wrapper"](#custom-wrapper) for existing function/method). This will let you
control when exactly it should release used resources or cancel unused
resources to let next delayed function/method run as soon as possible.

### throttle\_me

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
called using form `&throttle_me` because it needs to modify your
function/method's `@_`.

If your function/method should be delayed because of throttling it will
return false, and you should interrupt your function/method. Otherwise
it'll acquire "resources" needed to run your function/method and return
callback which you should call later to release these resources.

If your function/method has done it work (and thus "used" these resources)
`$done` should be called without parameters `$done->()` or with one
true param `$done->(1)`; if it hasn't done it work (and thus "not
used" these resources) it's better to call it with one false param
`$done->(0)` to cancel these unused resources and give a chance for
another function/method to reuse them.

If you forget to call `$done` - you'll get a warning (and chances are
you'll soon run out of resources because of this and new throttled
functions/methods won't be run anymore), if you call it more than once -
exception will be thrown.

Anonymous functions are not supported.

### throttle\_me\_asap

Same as ["throttle\_me"](#throttle_me) except use `&throttle_me_asap`:

        my $done = &throttle_me_asap || return;

This will make this async function/method use high-priority "asap" queue
instead of normal queue.

### throttle\_me\_sync

Similar to ["throttle\_me"](#throttle_me) but for sync function/method:

        my $done = &throttle_me_sync;

Delaying sync function/method is implemented using sleep(), so caller()
and wantarray() will work as expected, so only difference from usual
function/method is needs to call `&throttle_me_sync` on start and then
later release resources.

### done\_cb

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
call `$done->()` in your async function/method with throttling support.

First parameter must be ` $done ` callback, then either callback function
or object (or class name) and name of it method, and then optionally any
extra params for that callback function/object's method.

Returns callback, which when called will first call `$done->()` and then
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

## Implementing throttle algorithms/plugins

It's recommended to inherit your algorithm from [Sub::Throttler::algo](https://metacpan.org/pod/Sub::Throttler::algo).

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
function/method throttling engine may call `release_unused()` immediately
after successful `try_acquire()` - if it turns out some other resource
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

### throttle\_add

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
["apply\_to" in Sub::Throttler::algo](https://metacpan.org/pod/Sub::Throttler::algo#apply_to),
["apply\_to\_functions" in Sub::Throttler::algo](https://metacpan.org/pod/Sub::Throttler::algo#apply_to_functions),
["apply\_to\_methods" in Sub::Throttler::algo](https://metacpan.org/pod/Sub::Throttler::algo#apply_to_methods). But if algorithm doesn't
implement such helpers it may be used directly by user to apply some
algorithm instance to selected functions/methods.

### throttle\_del

    throttle_del();
    throttle_del($throttle_plugin);

Undo previous ["throttle\_add"](#throttle_add) calls with `$throttle_plugin` in first
param or all of them if given no param. This is rarely useful, usually you
setup throttling when your app initializes and then doesn't change it.

### throttle\_flush

    throttle_flush();

Algorithm **must** call it each time quantity of some resources increases
(so there is a chance one of delayed functions/methods can be run now).

# SUPPORT

## Bugs / Feature Requests

Please report any bugs or feature requests through the issue tracker
at [https://github.com/powerman/perl-Sub-Throttler/issues](https://github.com/powerman/perl-Sub-Throttler/issues).
You will be notified automatically of any progress on your issue.

## Source Code

This is open source software. The code repository is available for
public review and contribution under the terms of the license.
Feel free to fork the repository and submit pull requests.

[https://github.com/powerman/perl-Sub-Throttler](https://github.com/powerman/perl-Sub-Throttler)

    git clone https://github.com/powerman/perl-Sub-Throttler.git

## Resources

- MetaCPAN Search

    [https://metacpan.org/search?q=Sub-Throttler](https://metacpan.org/search?q=Sub-Throttler)

- CPAN Ratings

    [http://cpanratings.perl.org/dist/Sub-Throttler](http://cpanratings.perl.org/dist/Sub-Throttler)

- AnnoCPAN: Annotated CPAN documentation

    [http://annocpan.org/dist/Sub-Throttler](http://annocpan.org/dist/Sub-Throttler)

- CPAN Testers Matrix

    [http://matrix.cpantesters.org/?dist=Sub-Throttler](http://matrix.cpantesters.org/?dist=Sub-Throttler)

- CPANTS: A CPAN Testing Service (Kwalitee)

    [http://cpants.cpanauthors.org/dist/Sub-Throttler](http://cpants.cpanauthors.org/dist/Sub-Throttler)

# AUTHOR

Alex Efros &lt;powerman@cpan.org>

# COPYRIGHT AND LICENSE

This software is Copyright (c) 2014- by Alex Efros &lt;powerman@cpan.org>.

This is free software, licensed under:

    The MIT (X11) License
