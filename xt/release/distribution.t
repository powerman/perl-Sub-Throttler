use Test::More;

eval { require Test::Distribution };
plan( skip_all => 'Test::Distribution not installed' ) if $@;
Test::Distribution->import(
   podcoveropts => {
	coverage_class => 'Pod::Coverage::CountParents',
#        also_private    => [
#            qr/^(?:IMPORT)$/,
#        ],
#        pod_from        => 'MAIN PM FILE HERE',
   }
);
