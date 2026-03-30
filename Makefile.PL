use 5.010;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
	NAME             => 'App::prepare4release',
	VERSION_FROM     => 'lib/App/prepare4release.pm',
	ABSTRACT_FROM    => 'lib/App/prepare4release.pm',
	AUTHOR           => 'Sergey Kovalev <skov@cpan.org>',
	LICENSE          => 'perl',
	MIN_PERL_VERSION => '5.010.0',
	PREREQ_PM        => {
		'HTTP::Tiny' => 0.034,
		'JSON::PP'   => 0,
		'Pod::Usage' => 0,
	},
	# Used by t/*.t and xt/author/*.t. cpanm --installdeps . installs these for the
	# *same* perl as the cpanm executable — use that same perl for prove/make test
	# (see README). develop.* keeps Devel::Cover and other tooling-only deps.
	TEST_REQUIRES    => {
		'Module::CPANTS::Analyse'   => 0,
		'Module::CPANTS::Kwalitee'  => 0,
		'Test2::Suite'              => '0.000139',
		'Test::Compile'             => 0,
		'Test::EOL'                 => 0,
		'Test::Kwalitee'            => 0,
		'Test::MinimumVersion'      => 0,
		'Test::PAUSE::Permissions'  => 0,
		'Test::Pod'                 => 0,
		'Test::Pod::Coverage'       => 0,
		'Test::Portability::Files'  => 0,
		'Test::Synopsis'            => 0,
		'Test::Version'             => 0,
	},
	EXE_FILES        => ['bin/prepare4release'],
	META_MERGE       => {
		'meta-spec' => { version => 2 },
		prereqs     => {
			develop => {
				requires => {
					'Devel::Cover'           => 0,
					'Test::DependentModules' => 0,
				},
			},
		},
		resources => {
			repository => {
				type => 'git',
				url  => 'https://example.invalid/App-prepare4release.git',
				web  => 'https://example.invalid/',
			},
		},
	},
);
