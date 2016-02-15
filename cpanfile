requires 'perl', '5.010001';

requires 'AnyEvent';
requires 'EV';
requires 'Export::Attrs';
requires 'List::Util', '1.33';
requires 'Scalar::Util';
requires 'Time::HiRes';
requires 'parent';
requires 'version', '0.77';

on configure => sub {
    requires 'Module::Build::Tiny', '0.039';
};

on test => sub {
    requires 'Devel::CheckOS';
    requires 'JSON::XS';
    requires 'Test::Exception';
    requires 'Test::Mock::Time';
    requires 'Test::More', '0.96';
};

on develop => sub {
    requires 'Test::Perl::Critic';
};
