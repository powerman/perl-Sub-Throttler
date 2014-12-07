use 5.010001;
use strict;
use warnings;
use Module::Build;

my $class = Module::Build->subclass(
    class => 'Module::Build::Custom',
    code => <<'SUBCLASS' );

# Better compatibility with Gentoo ebuilds.
sub dist_version {
    my $self = shift;
    my $v = $self->SUPER::dist_version;
    $v =~ s/\Av//ms;
    return $v;
}
SUBCLASS

my $builder = $class->new(
    module_name         => 'Sub::Throttler',
    license             => 'mit',
    dist_author         => 'Alex Efros <powerman@cpan.org>',
    dist_version_from   => 'lib/Sub/Throttler.pm',
    release_status      => 'stable',
    configure_requires => {
        'Module::Build'         => 0,
    },
    requires => {
        'perl'                  => 5.010001,
        'version'               => '0.77',
        'Perl6::Export::Attrs'  => 0,
        'EV'                    => 0,
        'AnyEvent'              => 0,
        'Time::HiRes'           => 0,
    },
    test_requires => {
        'Test::More'            => 0,
        'Test::Exception'       => 0,
        'Test::CheckManifest'   => '0.9',
        'Test::Perl::Critic'    => 0,
        'Test::Pod'             => '1.22',
        'Test::Pod::Coverage'   => '1.08',
        'Pod::Coverage'         => '0.18',
        'JSON::XS'              => 0,
    },
#     add_to_cleanup     => [ 'Sub-Throttler-*' ],
);

$builder->create_build_script();
