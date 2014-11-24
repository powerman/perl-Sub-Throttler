use strict;
use warnings;
use utf8;
use feature ':5.10';
use open qw( :std :utf8 );
use Test::More;
use Test::Exception;

use Sub::Throttler::Rate::EV;

use EV;


my ($throttle, $t);

my $Flush = 0;
{ no warnings 'redefine';
  sub Sub::Throttler::Limit::throttle_flush { $Flush++ }
  sub Sub::Throttler::Rate::EV::throttle_flush { $Flush++ }
}

# - new
#   * значение limit по умолчанию 1
#   * значение period по умолчанию 1

$throttle = Sub::Throttler::Rate::EV->new;
ok $throttle->acquire('id1', 'key1', 1);
ok !$throttle->acquire('id2', 'key1', 1);
is $throttle->limit, 1,
    'limit = 1';

$t = EV::timer 1, 0, sub { EV::break };
EV::run;
ok $throttle->acquire('id2', 'key1', 1);
is $throttle->period, 1,
    'period = 1';

#   * при limit < 0 acquire не проходит

$throttle = Sub::Throttler::Rate::EV->new(limit => -2);
ok !$throttle->acquire('id1', 'key1', 1),
    'limit < 0';

#   * при limit = 0 acquire не проходит

$throttle = Sub::Throttler::Rate::EV->new(limit => 0);
ok !$throttle->acquire('id1', 'key1', 1),
    'limit = 0';

#   * при limit = n acquire даёт выделить до n (включительно) ресурса

$throttle = Sub::Throttler::Rate::EV->new(limit => 10);
$throttle->acquire('id1', 'key1', 3);
$throttle->acquire('id2', 'key1', 3);
$throttle->acquire('id3', 'key1', 3);
ok $throttle->acquire('id4', 'key1', 1),
    'acquire = n';
ok !$throttle->acquire('id5', 'key1', 1),
    'attempt to acquire more than n';

#   * ресурсы освобождаются не через period, а когда текущее время кратно period

$t = EV::periodic 0, 0.5, 0, sub { EV::break };
EV::run;
$t = EV::timer 0.3, 0, sub { EV::break };
EV::run;
$throttle = Sub::Throttler::Rate::EV->new(period => 0.5);
$throttle->acquire('id1', 'key1', 1);
ok !$throttle->acquire('id2', 'key1', 1),
    'resource was not released (time not multi-periodic)';
$t = EV::timer 0.3, 0, sub { EV::break };
EV::run;
ok $throttle->acquire('id2', 'key1', 1),
    'resource released';

# - acquire
#   * исключение при $quantity <= 0

$throttle = Sub::Throttler::Rate::EV->new;
throws_ok { $throttle->acquire('id1', 'key1', -1) } qr/quantity must be positive/,
    '$quantity < 0';
throws_ok { $throttle->acquire('id1', 'key1', 0) } qr/quantity must be positive/,
    '$quantity = 0';

#   * повторный запрос для тех же $id и $key кидает исключение

$throttle = Sub::Throttler::Rate::EV->new;
$throttle->acquire('id1', 'key1', 1);
throws_ok { $throttle->acquire('id1', 'key1', 1) } qr/already acquired/,
    'same $id and $key';

#   * возвращает истину/ложь в зависимости от того, удалось ли выделить
#     $quantity ресурсов для $key

$t = EV::periodic 0, 0.02, 0, sub { EV::break };
EV::run;
$throttle = Sub::Throttler::Rate::EV->new(limit => 5, period => 0.02);
ok $throttle->acquire('id1', 'key1', 4),
    'return true for $key';
ok !$throttle->acquire('id2', 'key1', 2),
    'return false for $key';

$t = EV::timer 0.01, 0, sub { EV::break };
EV::run;
ok !$throttle->acquire('id2', 'key1', 2);
$t = EV::timer 0.01, 0, sub { EV::break };
EV::run;
ok $throttle->acquire('id2', 'key1', 2);

#   (использовать used() для контроля текущего значения)
#   * использовать разные значения $quantity так, чтобы последний acquire
#     попытался выделить:
#     - текущее значение меньше limit, выделяется ровно под limit

$throttle = Sub::Throttler::Rate::EV->new(limit => 5);
$throttle->acquire('id1', 'key1', 3);
is $throttle->used('key1'), 3,
    'used()';
ok $throttle->acquire('id2', 'key1', 2),
    'value < limit, acquiring to limit';
is $throttle->used('key1'), 5;

#     - текущее значение меньше limit, выделяется больше limit

$throttle = Sub::Throttler::Rate::EV->new(limit => 5);
$throttle->acquire('id1', 'key1', 3);
ok !$throttle->acquire('id2', 'key1', 3),
    'value < limit, acquiring above limit';
is $throttle->used('key1'), 3;

#     - текущее значение равно limit, выделяется 1

$throttle = Sub::Throttler::Rate::EV->new(limit => 5);
$throttle->acquire('id1', 'key1', 5);
ok !$throttle->acquire('id2', 'key1', 1),
    'value = limit, acquire 1';

#   * под разные $key ресурсы выделяются независимо

$throttle = Sub::Throttler::Rate::EV->new(limit => 5);
ok $throttle->acquire('id1', 'key1', 5);
ok $throttle->acquire('id1', 'key2', 5),
    'different $key are independent';

#   * увеличиваем текущий limit()
#     - проходят acquire, которые до этого не проходили

$throttle = Sub::Throttler::Rate::EV->new(limit => 5);
$throttle->acquire('id1', 'key1', 4);
ok !$throttle->acquire('id2', 'key1', 4);
$throttle->limit(10);
ok $throttle->acquire('id2', 'key1', 4),
    'increase current limit()';

#   * уменьшить текущий limit()
#     - не проходят acquire, которые до этого бы прошли

$throttle = Sub::Throttler::Rate::EV->new(limit => 10);
$throttle->acquire('id1', 'key1', 4);
$throttle->limit(5);
ok !$throttle->acquire('id2', 'key1', 4),
    'decrease current limit()';

# - release, release_unused
#   * кидает исключение если для $id нет выделенных ресурсов

$throttle = Sub::Throttler::Rate::EV->new;
throws_ok { $throttle->release('id1') } qr/not acquired/,
    'no acquired resourced for $id';
throws_ok { $throttle->release_unused('id1') } qr/not acquired/,
    'no acquired resourced for $id';

#   (использовать used() для контроля текущего значения)
#   * release не освобождает ресурсы, release_unused освобождает
#     все ресурсы ($key+$quantity), выделенные для $id, если вызывается
#     в тот же период времени, когда они были захвачены
#     - под $id был выделен один $key, период тот же

$throttle = Sub::Throttler::Rate::EV->new(limit => 2);
$throttle->acquire('id1', 'key1', 1);
$throttle->acquire('id2', 'key2', 2);
ok !$throttle->acquire('id3', 'key1', 2);
ok !$throttle->acquire('id3', 'key2', 1);
is $throttle->used('key1'), 1;
$throttle->release_unused('id1');
is $throttle->used('key1'), 0;
ok $throttle->acquire('id3', 'key1', 2);
ok !$throttle->acquire('id3', 'key2', 1);
is $throttle->used('key2'), 2;
$throttle->release('id2');
is $throttle->used('key2'), 2;
ok !$throttle->acquire('id3', 'key2', 1);

#     - под $id был выделен один $key, период другой

$throttle = Sub::Throttler::Rate::EV->new(limit => 2, period => 0.01);
$throttle->acquire('id1', 'key1', 1);
$throttle->acquire('id2', 'key2', 2);
ok !$throttle->acquire('id3', 'key1', 2);
ok !$throttle->acquire('id3', 'key2', 1);
is $throttle->used('key1'), 1;
is $throttle->used('key2'), 2;
$t = EV::timer 0.01, 0, sub { EV::break };
EV::run;
is $throttle->used('key1'), 0;
is $throttle->used('key2'), 0;
lives_ok  { $throttle->release_unused('id1') };
throws_ok { $throttle->release_unused('id1') } qr/not acquired/;
lives_ok  { $throttle->release('id2') };
throws_ok { $throttle->release('id2') } qr/not acquired/;
is $throttle->used('key1'), 0;
is $throttle->used('key2'), 0;

#     - под $id было выделено несколько $key, период тот же

$throttle = Sub::Throttler::Rate::EV->new(limit => 5);
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

$throttle = Sub::Throttler::Rate::EV->new(limit => 5, period => 0.01);
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
is $throttle->used('key1'), 1;
is $throttle->used('key2'), 2;
is $throttle->used('key3'), 3;
is $throttle->used('key4'), 4;
is $throttle->used('key5'), 5;
$t = EV::timer 0.01, 0, sub { EV::break };
EV::run;
is $throttle->used('key1'), 0;
is $throttle->used('key2'), 0;
is $throttle->used('key3'), 0;
is $throttle->used('key4'), 0;
is $throttle->used('key5'), 0;
lives_ok  { $throttle->release('id1') };
throws_ok { $throttle->release('id1') } qr/not acquired/;
lives_ok  { $throttle->release_unused('id2') };
throws_ok { $throttle->release_unused('id2') } qr/not acquired/;
is $throttle->used('key1'), 0;
is $throttle->used('key2'), 0;
is $throttle->used('key3'), 0;
is $throttle->used('key4'), 0;
is $throttle->used('key5'), 0;

#   * уменьшить текущий limit()
#     - после release текущее значение всё ещё >= limit, и acquire не проходит

$throttle = Sub::Throttler::Rate::EV->new(limit => 5);
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
$throttle = Sub::Throttler::Rate::EV->new(limit => 5);
$throttle->acquire('id1', 'key1', 5);
$throttle->acquire('id2', 'key2', 5);
$throttle->release('id1');
is $Flush, 0;
$throttle->release_unused('id2');
is $Flush, 1;

#   * Sub::Throttler::throttle_flush() вызывается каждый period (не важно,
#     освободились какие-то ресурсы, или нет)

$Flush = 0;
$throttle = Sub::Throttler::Rate::EV->new(period => 0.05);
$throttle->acquire('id1', 'key1', 1);
$t = EV::timer 0.05, 0, sub { EV::break };
EV::run;
is $Flush, 1,
    'throttle_flush() called every period';
$t = EV::timer 0.05, 0, sub { EV::break };
EV::run;
is $Flush, 2;

# - used
#   * уменьшение текущего значения (напр. установка отрицательного
#     значения, если текущее было 0)
#     - для такого $key доступный limit фактически увеличивается на
#       столько, на сколько уменьшили used

$throttle = Sub::Throttler::Rate::EV->new(limit => 5);
$throttle->used('key1', -5);
ok $throttle->acquire('id1', 'key1', 10);
ok !$throttle->acquire('id1', 'key2', 10);
is $throttle->used('key1'), 5;

#   * увеличение текущего значения
#     - для такого $key доступный limit фактически уменьшается на столько,
#       на сколько увеличили used

$throttle = Sub::Throttler::Rate::EV->new(limit => 5);
$throttle->used('key1', 5);
$throttle->used('key2', 4);
ok !$throttle->acquire('id1', 'key1', 1);
ok $throttle->acquire('id1', 'key2', 1);
is $throttle->used('key1'), 5;
is $throttle->used('key2'), 5;

#   * при изменении used вызывается Sub::Throttler::throttle_flush

$throttle = Sub::Throttler::Limit->new(limit => 5);
$Flush = 0;
$throttle->used('key1', 5);
is $Flush, 1;

#   # - limit
#   #   * при изменении limit() вызывается Sub::Throttler::throttle_flush

$throttle = Sub::Throttler::Limit->new(limit => 5);
$Flush = 0;
$throttle->limit(3);
is $Flush, 1;

# - apply_to
#   * некорректные параметры:
#     - не 2 параметра

$throttle = Sub::Throttler::Rate::EV->new;
throws_ok { $throttle->apply_to() } qr/require 2 params/;

#     - второй не ссылка на функцию

throws_ok { $throttle->apply_to(undef) } qr/target must be CODE/;
throws_ok { $throttle->apply_to('asd') } qr/target must be CODE/;
throws_ok { $throttle->apply_to(42) } qr/target must be CODE/;
throws_ok { $throttle->apply_to([1,2,3]) } qr/target must be CODE/;
throws_ok { $throttle->apply_to({key1 => 1, key2 => 2}) } qr/target must be CODE/;


done_testing();
