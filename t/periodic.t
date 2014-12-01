use strict;
use warnings;
use utf8;
use feature ':5.10';
use open qw( :std :utf8 );
use Test::More;
use Test::Exception;

use Sub::Throttler::Periodic;

use Time::HiRes qw( time sleep );


my $throttle;

my $Flush = 0;
{ no warnings 'redefine';
  sub Sub::Throttler::Limit::throttle_flush { $Flush++ }
  sub Sub::Throttler::Periodic::throttle_flush { $Flush++ }
}

# - new
#   * значение limit по умолчанию 1
#   * значение period по умолчанию 1

$throttle = Sub::Throttler::Periodic->new;
ok $throttle->acquire('id1', 'key1', 1);
ok !$throttle->acquire('id2', 'key1', 1);
is $throttle->limit, 1,
    'limit = 1';

sleep 1; $throttle->tick();
ok $throttle->acquire('id2', 'key1', 1);
is $throttle->period, 1,
    'period = 1';

#   * при limit < 0 acquire не проходит

$throttle = Sub::Throttler::Periodic->new(limit => -2);
ok !$throttle->acquire('id1', 'key1', 1),
    'limit < 0';

#   * при limit = 0 acquire не проходит

$throttle = Sub::Throttler::Periodic->new(limit => 0);
ok !$throttle->acquire('id1', 'key1', 1),
    'limit = 0';

#   * при limit = n acquire даёт выделить до n (включительно) ресурса

$throttle = Sub::Throttler::Periodic->new(limit => 10);
$throttle->acquire('id1', 'key1', 3);
$throttle->acquire('id2', 'key1', 3);
$throttle->acquire('id3', 'key1', 3);
ok $throttle->acquire('id4', 'key1', 1),
    'acquire = n';
ok !$throttle->acquire('id5', 'key1', 1),
    'attempt to acquire more than n';

#   * некорректные параметры

throws_ok { Sub::Throttler::Periodic->new('limit') } qr/hash/;
throws_ok { Sub::Throttler::Periodic->new(duration => 1) } qr/bad param/;
throws_ok { Sub::Throttler::Periodic->new(duration => 1, limit => 1) } qr/bad param/;

#   * ресурсы освобождаются не через period, а когда текущее время кратно period

sleep int(time/0.5)*0.5+0.5-time();
sleep 0.3;
$throttle = Sub::Throttler::Periodic->new(period => 0.5);
$throttle->acquire('id1', 'key1', 1);
ok !$throttle->acquire('id2', 'key1', 1),
    'resource was not released (time not multi-periodic)';
sleep 0.3; $throttle->tick();
ok $throttle->acquire('id2', 'key1', 1),
    'resource released';

# - acquire
#   * исключение при $quantity <= 0

$throttle = Sub::Throttler::Periodic->new;
throws_ok { $throttle->acquire('id1', 'key1', -1) } qr/quantity must be positive/,
    '$quantity < 0';
throws_ok { $throttle->acquire('id1', 'key1', 0) } qr/quantity must be positive/,
    '$quantity = 0';

#   * повторный запрос для тех же $id и $key кидает исключение

$throttle = Sub::Throttler::Periodic->new;
$throttle->acquire('id1', 'key1', 1);
throws_ok { $throttle->acquire('id1', 'key1', 1) } qr/already acquired/,
    'same $id and $key';

#   * возвращает истину/ложь в зависимости от того, удалось ли выделить
#     $quantity ресурсов для $key

sleep int(time/0.2)*0.2+0.2-time();
$throttle = Sub::Throttler::Periodic->new(limit => 5, period => 0.2);
ok $throttle->acquire('id1', 'key1', 4),
    'return true for $key';
ok !$throttle->acquire('id2', 'key1', 2),
    'return false for $key';

sleep 0.1; $throttle->tick();
ok !$throttle->acquire('id2', 'key1', 2);
sleep 0.1; $throttle->tick();
ok $throttle->acquire('id2', 'key1', 2);

#   (использовать {used} для контроля текущего значения)
#   * использовать разные значения $quantity так, чтобы последний acquire
#     попытался выделить:
#     - текущее значение меньше limit, выделяется ровно под limit

$throttle = Sub::Throttler::Periodic->new(limit => 5);
$throttle->acquire('id1', 'key1', 3);
is $throttle->{used}{key1}, 3,
    'used';
ok $throttle->acquire('id2', 'key1', 2),
    'value < limit, acquiring to limit';
is $throttle->{used}{key1}, 5;

#     - текущее значение меньше limit, выделяется больше limit

$throttle = Sub::Throttler::Periodic->new(limit => 5);
$throttle->acquire('id1', 'key1', 3);
ok !$throttle->acquire('id2', 'key1', 3),
    'value < limit, acquiring above limit';
is $throttle->{used}{key1}, 3;

#     - текущее значение равно limit, выделяется 1

$throttle = Sub::Throttler::Periodic->new(limit => 5);
$throttle->acquire('id1', 'key1', 5);
ok !$throttle->acquire('id2', 'key1', 1),
    'value = limit, acquire 1';

#   * под разные $key ресурсы выделяются независимо

$throttle = Sub::Throttler::Periodic->new(limit => 5);
ok $throttle->acquire('id1', 'key1', 5);
ok $throttle->acquire('id1', 'key2', 5),
    'different $key are independent';

#   * увеличиваем текущий limit()
#     - проходят acquire, которые до этого не проходили

$throttle = Sub::Throttler::Periodic->new(limit => 5);
$throttle->acquire('id1', 'key1', 4);
ok !$throttle->acquire('id2', 'key1', 4);
$throttle->limit(10);
ok $throttle->acquire('id2', 'key1', 4),
    'increase current limit()';

#   * уменьшить текущий limit()
#     - не проходят acquire, которые до этого бы прошли

$throttle = Sub::Throttler::Periodic->new(limit => 10);
$throttle->acquire('id1', 'key1', 4);
$throttle->limit(5);
ok !$throttle->acquire('id2', 'key1', 4),
    'decrease current limit()';

# - release, release_unused
#   * кидает исключение если для $id нет выделенных ресурсов

$throttle = Sub::Throttler::Periodic->new;
throws_ok { $throttle->release('id1') } qr/not acquired/,
    'no acquired resourced for $id';
throws_ok { $throttle->release_unused('id1') } qr/not acquired/,
    'no acquired resourced for $id';

#   (использовать {used} для контроля текущего значения)
#   * release не освобождает ресурсы, release_unused освобождает
#     все ресурсы ($key+$quantity), выделенные для $id, если вызывается
#     в тот же период времени, когда они были захвачены
#     - под $id был выделен один $key, период тот же

$throttle = Sub::Throttler::Periodic->new(limit => 2);
$throttle->acquire('id1', 'key1', 1);
$throttle->acquire('id2', 'key2', 2);
ok !$throttle->acquire('id3', 'key1', 2);
ok !$throttle->acquire('id3', 'key2', 1);
is $throttle->{used}{key1}, 1;
$throttle->release_unused('id1');
is $throttle->{used}{key1}, undef;
ok $throttle->acquire('id3', 'key1', 2);
ok !$throttle->acquire('id3', 'key2', 1);
is $throttle->{used}{key2}, 2;
$throttle->release('id2');
is $throttle->{used}{key2}, 2;
ok !$throttle->acquire('id3', 'key2', 1);

#     - под $id был выделен один $key, период другой

$throttle = Sub::Throttler::Periodic->new(limit => 2, period => 0.1);
$throttle->acquire('id1', 'key1', 1);
$throttle->acquire('id2', 'key2', 2);
ok !$throttle->acquire('id3', 'key1', 2);
ok !$throttle->acquire('id3', 'key2', 1);
is $throttle->{used}{key1}, 1;
is $throttle->{used}{key2}, 2;
sleep 0.1; $throttle->tick();
is $throttle->{used}{key1}, undef;
is $throttle->{used}{key2}, undef;
lives_ok  { $throttle->release_unused('id1') };
throws_ok { $throttle->release_unused('id1') } qr/not acquired/;
lives_ok  { $throttle->release('id2') };
throws_ok { $throttle->release('id2') } qr/not acquired/;
is $throttle->{used}{key1}, undef;
is $throttle->{used}{key2}, undef;

#     - под $id было выделено несколько $key, период тот же

$throttle = Sub::Throttler::Periodic->new(limit => 5);
$throttle->acquire('id1', 'key1', 1);
$throttle->acquire('id1', 'key2', 2);
$throttle->acquire('id1', 'key3', 3);
$throttle->acquire('id2', 'key4', 4);
$throttle->acquire('id2', 'key5', 5);
ok !$throttle->acquire('id3', 'key1', 5);
ok !$throttle->acquire('id3', 'key2', 4);
ok !$throttle->acquire('id3', 'key3', 3);
ok !$throttle->acquire('id3', 'key4', 2);
ok !$throttle->acquire('id3', 'key5', 1);
$throttle->release('id1');
ok !$throttle->acquire('id3', 'key1', 5);
ok !$throttle->acquire('id3', 'key2', 4);
ok !$throttle->acquire('id3', 'key3', 3);
ok !$throttle->acquire('id3', 'key4', 2);
ok !$throttle->acquire('id3', 'key5', 1);
$throttle->release_unused('id2');
ok $throttle->acquire('id3', 'key4', 2);
ok $throttle->acquire('id3', 'key5', 1);

#     - под $id было выделено несколько $key, период другой

$throttle = Sub::Throttler::Periodic->new(limit => 5, period => 0.01);
$throttle->acquire('id1', 'key1', 1);
$throttle->acquire('id1', 'key2', 2);
$throttle->acquire('id1', 'key3', 3);
$throttle->acquire('id2', 'key4', 4);
$throttle->acquire('id2', 'key5', 5);
ok !$throttle->acquire('id3', 'key1', 5);
ok !$throttle->acquire('id3', 'key2', 4);
ok !$throttle->acquire('id3', 'key3', 3);
ok !$throttle->acquire('id3', 'key4', 2);
ok !$throttle->acquire('id3', 'key5', 1);
is $throttle->{used}{key1}, 1;
is $throttle->{used}{key2}, 2;
is $throttle->{used}{key3}, 3;
is $throttle->{used}{key4}, 4;
is $throttle->{used}{key5}, 5;
sleep 0.01; $throttle->tick();
is $throttle->{used}{key1}, undef;
is $throttle->{used}{key2}, undef;
is $throttle->{used}{key3}, undef;
is $throttle->{used}{key4}, undef;
is $throttle->{used}{key5}, undef;
lives_ok  { $throttle->release('id1') };
throws_ok { $throttle->release('id1') } qr/not acquired/;
lives_ok  { $throttle->release_unused('id2') };
throws_ok { $throttle->release_unused('id2') } qr/not acquired/;
is $throttle->{used}{key1}, undef;
is $throttle->{used}{key2}, undef;
is $throttle->{used}{key3}, undef;
is $throttle->{used}{key4}, undef;
is $throttle->{used}{key5}, undef;

#   * уменьшить текущий limit()
#     - после release текущее значение всё ещё >= limit, и acquire не проходит

$throttle = Sub::Throttler::Periodic->new(limit => 5);
$throttle->acquire('id1', 'key1', 1);
$throttle->acquire('id2', 'key2', 2);
$throttle->acquire('id3', 'key1', 4);
$throttle->acquire('id3', 'key2', 3);
$throttle->limit(3);
$throttle->release('id1');
ok !$throttle->acquire('id1', 'key1', 1);
$throttle->release_unused('id2');
ok !$throttle->acquire('id2', 'key2', 1);

# - при освобождении ресурсов вызывается Sub::Throttler::throttle_flush()
#   * только release_unused вызывает Sub::Throttler::throttle_flush()

$Flush = 0;
$throttle = Sub::Throttler::Periodic->new(limit => 5);
$throttle->acquire('id1', 'key1', 5);
$throttle->acquire('id2', 'key2', 5);
$throttle->release('id1');
is $Flush, 0;
$throttle->release_unused('id2');
is $Flush, 1;

#   * Sub::Throttler::throttle_flush() вызывается каждый period в котором
#     были захвачены ресурсы (а значит они были освобождены в конце period)

$Flush = 0;
$throttle = Sub::Throttler::Periodic->new(period => 0.5);
$throttle->acquire('id1', 'key1', 1);
sleep 0.5; $throttle->tick();
is $Flush, 1,
    'resource was acquired: throttle_flush() called after period';
sleep 0.5; $throttle->tick();
is $Flush, 1,
    'resource was not acquired: throttle_flush() not called after period';
$throttle->acquire('id1', 'key2', 1);
sleep 0.5; $throttle->tick();
is $Flush, 2,
    'resource was acquired: throttle_flush() called after period';
$throttle->acquire('id1', 'key3', 2);
sleep 0.5; $throttle->tick();
is $Flush, 2,
    'resource failed to acquire: throttle_flush() not called after period';

# - limit
#   * при увеличении limit() вызывается Sub::Throttler::throttle_flush

$throttle = Sub::Throttler::Periodic->new(limit => 5);
$Flush = 0;
$throttle->limit(3);
is $Flush, 0;
$throttle->limit(4);
is $Flush, 1;

#   * chaining

is $throttle->limit(4), $throttle;

# - period
#   * изменение period срабатывает сразу

$Flush = 0;

sleep int(time/0.5)*0.5+0.5-time();
$throttle = Sub::Throttler::Periodic->new(period => 0.5);
is $throttle->period, 0.5,
    'period set to 0.5';
$throttle->acquire('id1', 'key1', 1);
sleep 0.3; $throttle->tick();
is $Flush, 0,
    'period > 0.3';
sleep 0.3; $throttle->tick();
is $Flush, 1,
    'period < 0.6';

sleep int(time/0.1)*0.1+0.1-time();
$throttle->acquire('id1', 'key2', 1);
$throttle->period(0.1);
is $throttle->period, 0.1,
    'set period to 0.1';
sleep 0.3; $throttle->tick();
is $Flush, 2,
    'period < 0.3';

sleep int(time/0.5)*0.5+0.5-time();
$throttle->acquire('id1', 'key3', 1);
$throttle->period(0.5);
is $throttle->period, 0.5,
    'set period to 0.5';
sleep 0.3; $throttle->tick();
is $Flush, 2,
    'period > 0.3';
sleep 0.3; $throttle->tick();
is $Flush, 3,
    'period < 0.6';

#   * chaining

is $throttle->period(0.5), $throttle;

# - apply_to
#   * некорректные параметры:
#     - не 2 параметра

$throttle = Sub::Throttler::Periodic->new;
throws_ok { $throttle->apply_to() } qr/require 2 params/;

#     - второй не ссылка на функцию

throws_ok { $throttle->apply_to(undef) } qr/target must be CODE/;
throws_ok { $throttle->apply_to('asd') } qr/target must be CODE/;
throws_ok { $throttle->apply_to(42) } qr/target must be CODE/;
throws_ok { $throttle->apply_to([1,2,3]) } qr/target must be CODE/;
throws_ok { $throttle->apply_to({key1 => 1, key2 => 2}) } qr/target must be CODE/;


done_testing();
