package App::prepare4release;

use strict;
use warnings;
use utf8;

our $VERSION = '0.001';

use Carp qw(croak);
use Cwd qw(getcwd);
use File::Find ();
use File::Path qw(make_path);
use File::Spec ();
use JSON::PP ();
use Pod::Usage qw(pod2usage);
use version ();

sub DEFAULT_CONFIG_FILENAME {'prepare4release.json'}

sub new {
	my ( $class, %arg ) = @_;
	my $self = bless {
		config_path => $arg{config_path},
		config      => $arg{config},
		opts        => $arg{opts} // {},
		identity    => $arg{identity} // {},
	}, $class;
	return $self;
}

# --- JSON "git" section ------------------------------------------------------

sub git_hash {
	my ( $class, $config ) = @_;
	$config = {} unless ref $config eq 'HASH';
	my $g = $config->{git};
	return {} unless ref $g eq 'HASH';
	return {%$g};
}

sub git_author {
	my ( $class, $config ) = @_;
	my $g = $class->git_hash($config);
	my $a = $g->{author};
	return $a if defined $a && length $a;
	return;
}

sub git_repo_name {
	my ( $class, $config ) = @_;
	my $g = $class->git_hash($config);
	my $r = $g->{repo};
	return $r if defined $r && length $r;
	return;
}

sub git_server {
	my ( $class, $config ) = @_;
	my $g = $class->git_hash($config);
	my $s = $g->{server};
	if ( defined $s && length $s ) {
		$s =~ s{\Ahttps?://}{}i;
		$s =~ s{/\z}{};
		return $s;
	}
	return;
}

# --- Host / URLs -------------------------------------------------------------

sub effective_git_host {
	my ( $class, $opts, $config ) = @_;
	my $srv = $class->git_server($config);
	return $srv if defined $srv && length $srv;
	return 'gitlab.com' if $opts->{gitlab};
	return 'github.com';
}

sub https_base {
	my ( $class, $host ) = @_;
	$host =~ s{/\z}{};
	return "https://$host";
}

sub package_to_repo_default {
	my ( $class, $module_name ) = @_;
	croak 'module_name required' unless defined $module_name && length $module_name;
	( my $copy = $module_name ) =~ s/::/-/g;
	return 'perl-' . $copy;
}

sub module_repo {
	my ($self) = @_;
	my $cfg = $self->{config} // {};
	my $id  = $self->{identity} // {};
	my $mod = $id->{module_name};
	croak 'module_name is required to derive module_repo'
		unless defined $mod && length $mod;

	my $explicit = __PACKAGE__->git_repo_name($cfg);
	return $explicit if defined $explicit && length $explicit;
	return __PACKAGE__->package_to_repo_default($mod);
}

sub repository_path_segment {
	my ($self) = @_;
	my $author = __PACKAGE__->git_author( $self->{config} // {} );
	croak 'git.author is required for repository URLs'
		unless defined $author && length $author;
	my $repo = $self->module_repo;
	return "$author/$repo";
}

sub repository_web_url {
	my ($self) = @_;
	my $opts = $self->{opts} // {};
	my $cfg  = $self->{config} // {};
	my $base = __PACKAGE__->https_base(
		__PACKAGE__->effective_git_host( $opts, $cfg ) );
	return $base . '/' . $self->repository_path_segment;
}

sub repository_git_url {
	my ($self) = @_;
	return $self->repository_web_url . '.git';
}

sub bugtracker_url {
	my ($self) = @_;
	my $cfg = $self->{config} // {};
	if ( ref $cfg eq 'HASH' && defined $cfg->{bugtracker} && length $cfg->{bugtracker} ) {
		return $cfg->{bugtracker};
	}
	return $self->repository_web_url . '/issues';
}

# --- Makefile.PL discovery ---------------------------------------------------

sub makefile_pl_path {
	my ($class) = @_;
	my $cwd = getcwd();
	my $p = File::Spec->catfile( $cwd, 'Makefile.PL' );
	return -e $p ? $p : undef;
}

sub read_makefile_pl_snippets {
	my ( $class, $path ) = @_;
	open my $fh, '<:encoding(UTF-8)', $path
		or croak "Cannot open Makefile.PL '$path': $!";
	local $/;
	my $s = <$fh>;
	close $fh;

	my %out;
	if ( $s =~ /VERSION_FROM\s*=>\s*['"]([^'"]+)['"]/ ) {
		$out{version_from} = $1;
	}
	if ( $s =~ /NAME\s*=>\s*['"]([^'"]+)['"]/ ) {
		$out{name} = $1;
	}
	if ( $s =~ /LICENSE\s*=>\s*['"]([^'"]+)['"]/ ) {
		$out{license} = $1;
	}
	return ( $s, \%out );
}

sub find_lib_pm_files {
	my ( $class, $cwd ) = @_;
	my $lib = File::Spec->catfile( $cwd, 'lib' );
	return () unless -d $lib;
	my @files;
	File::Find::find(
		sub {
			return unless -f && /\.pm\z/;
			push @files, $File::Find::name;
		},
		$lib
	);
	return @files;
}

sub parse_pm_identity {
	my ( $class, $path ) = @_;
	open my $fh, '<:encoding(UTF-8)', $path
		or croak "Cannot open '$path': $!";
	my $pkg;
	my $ver;
	while ( my $line = <$fh> ) {
		if ( !$pkg && $line =~ /^\s*package\s+([\w:]+)\s*;/ ) {
			$pkg = $1;
		}
		if ( $line =~ /\$VERSION\s*=\s*([^;\s]+)\s*;/ ) {
			my $raw = $1;
			$raw =~ s/^(['"])(.*)\1\z/$2/s;
			$ver = $raw;
		}
	}
	close $fh;
	return ( $pkg, $ver );
}

sub resolve_identity {
	my ( $class, $cwd, $config, $mf_snippets ) = @_;
	$config = {} unless ref $config eq 'HASH';

	my $module_name = $config->{module_name};
	my $version     = $config->{version};
	my $dist_name   = $config->{dist_name};

	my $vf_rel = $mf_snippets->{version_from};
	my $vf_abs;
	if ($vf_rel) {
		$vf_abs = File::Spec->rel2abs( $vf_rel, $cwd );
	}

	if ( ( !$module_name || !length $module_name ) && $vf_abs && -e $vf_abs ) {
		my $v_from_file;
		( $module_name, $v_from_file ) = $class->parse_pm_identity($vf_abs);
		$version //= $v_from_file if defined $v_from_file;
	}

	if ( ( !$module_name || !length $module_name ) && $mf_snippets->{name} ) {
		$module_name = $mf_snippets->{name};
	}

	if ( ( !$module_name || !length $module_name ) ) {
		my @candidates = $class->find_lib_pm_files($cwd);
		for my $f ( sort @candidates ) {
			my ( $p, $v ) = $class->parse_pm_identity($f);
			if ($p) {
				$module_name = $p;
				$vf_abs = $f;
				$version //= $v if defined $v;
				last;
			}
		}
	}

	if ( $vf_abs && -e $vf_abs && !defined $version ) {
		my $v2;
		( undef, $v2 ) = $class->parse_pm_identity($vf_abs);
		$version = $v2 if defined $v2;
	}

	if ( !$dist_name && $module_name ) {
		( my $d = $module_name ) =~ s/::/-/g;
		$dist_name = $d;
	}

	return {
		module_name => $module_name,
		version     => $version,
		dist_name   => $dist_name,
		version_from_path => $vf_abs,
	};
}

# --- Makefile.PL patches -----------------------------------------------------

sub POSTAMBLE_POD2GITHUB {
	my $tab = "\t";
	return <<"EOF";
sub MY::postamble {
  return '' if !-e '.git';
  <<'POD2README';
pure_all :: README.md

README.md : \$(VERSION_FROM)
${tab}pod2github \$< \$@
POD2README
}
EOF
}

sub POSTAMBLE_POD2MARKDOWN {
	my $tab = "\t";
	return <<"EOF";
sub MY::postamble {
  return '' if !-e '.git';
  <<'POD2README';
pure_all :: README.md

README.md : \$(VERSION_FROM)
${tab}pod2markdown \$< \$@
POD2README
}
EOF
}

sub makefile_has_pod2github {
	my ( $class, $content ) = @_;
	return $content =~ /pod2github\b/;
}

sub makefile_has_pod2markdown {
	my ( $class, $content ) = @_;
	return $content =~ /pod2markdown\b/;
}

sub ensure_postamble {
	my ( $class, $content, $want_pod2github, $verbose ) = @_;

	if ($want_pod2github) {
		if ( $class->makefile_has_pod2github($content) ) {
			warn "[prepare4release] Makefile.PL: pod2github already present, skipping postamble\n"
				if $verbose;
			return $content;
		}
		if ( $class->makefile_has_pod2markdown($content) ) {
			warn "[prepare4release] Makefile.PL: pod2markdown present (not replacing with pod2github); skipping\n"
				if $verbose;
			return $content;
		}
	}
	else {
		if ( $class->makefile_has_pod2markdown($content) ) {
			warn "[prepare4release] Makefile.PL: pod2markdown already present, skipping postamble\n"
				if $verbose;
			return $content;
		}
		if ( $class->makefile_has_pod2github($content) ) {
			warn "[prepare4release] Makefile.PL: pod2github present (not replacing with pod2markdown); skipping\n"
				if $verbose;
			return $content;
		}
	}

	my $block = $want_pod2github ? $class->POSTAMBLE_POD2GITHUB : $class->POSTAMBLE_POD2MARKDOWN;
	if ( $content =~ /sub\s+MY::postamble\b/ ) {
		warn "[prepare4release] Makefile.PL: MY::postamble exists but required pod2* rule missing; not auto-merging\n"
			if $verbose;
		return $content;
	}

	$content =~ s/\s*\z/\n/;
	return $content . "\n" . $block;
}

sub write_makefile_close_index {
	my ( $class, $content ) = @_;
	my $start = index( $content, 'WriteMakefile(' );
	return if $start < 0;
	my $open = $start + length('WriteMakefile');
	my $depth = 0;
	my $len = length $content;
	for ( my $i = $open ; $i < $len ; $i++ ) {
		my $c = substr( $content, $i, 1 );
		if ( $c eq '(' ) {
			$depth++;
		}
		elsif ( $c eq ')' ) {
			$depth--;
			if ( $depth == 0 ) {
				return [ $start, $i ];
			}
		}
	}
	return;
}

sub meta_merge_block {
	my ( $class, $repo_git_url, $repo_web, $bugtracker_web ) = @_;
	my $block = <<"META";
	META_MERGE       => {
		'meta-spec' => { version => 2 },
		resources   => {
			repository => {
				type => 'git',
				url  => '$repo_git_url',
				web  => '$repo_web',
			},
			bugtracker => {
				web => '$bugtracker_web',
			},
		},
	},
META
	return $block;
}

sub ensure_meta_merge {
	my ( $class, $content, $repo_git_url, $repo_web, $bugtracker_web, $verbose ) = @_;

	my $has_repo_urls = $content =~ /\Q$repo_git_url\E/s && $content =~ /\Q$repo_web\E/s;
	my $has_bug       = $content =~ /\Q$bugtracker_web\E/s;

	if ( $has_repo_urls && $has_bug ) {
		warn "[prepare4release] Makefile.PL: META_MERGE repository/bugtracker URLs already match, skipping\n"
			if $verbose;
		return $content;
	}

	if ( $content =~ /\bMETA_MERGE\b/ ) {
		$content = $class->_patch_meta_merge_block(
			$content, $repo_git_url, $repo_web, $bugtracker_web, $verbose
		);
		return $content;
	}

	my $meta = $class->meta_merge_block( $repo_git_url, $repo_web, $bugtracker_web );
	my $pair = $class->write_makefile_close_index($content);
	if ( !$pair ) {
		warn "[prepare4release] Makefile.PL: WriteMakefile( not found, cannot insert META_MERGE\n"
			if $verbose;
		return $content;
	}
	my ( $wm_start, $close_idx ) = @{$pair};
	substr( $content, $close_idx, 0 ) = ",\n" . $meta;
	return $content;
}

sub _patch_meta_merge_block {
	my ( $class, $content, $repo_git_url, $repo_web, $bugtracker_web, $verbose ) = @_;

	if ( $content =~ s/(repository\s*=>\s*\{[^}]*?)(\burl\s*=>\s*)'[^']*'/${1}${2}'$repo_git_url'/s ) {
		1;
	}
	elsif ( $content =~ s/(repository\s*=>\s*\{[^}]*?)(\burl\s*=>\s*)"[^"]*"/${1}${2}"$repo_git_url"/s ) {
		1;
	}
	if ( $content =~ s/(repository\s*=>\s*\{[^}]*?)(\bweb\s*=>\s*)'[^']*'/${1}${2}'$repo_web'/s ) {
		1;
	}
	elsif ( $content =~ s/(repository\s*=>\s*\{[^}]*?)(\bweb\s*=>\s*)"[^"]*"/${1}${2}"$repo_web"/s ) {
		1;
	}

	if ( $content =~ /bugtracker\s*=>\s*\{/ ) {
		if ( $content =~ s/(bugtracker\s*=>\s*\{[^}]*?)(\bweb\s*=>\s*)'[^']*'/${1}${2}'$bugtracker_web'/s ) {
			1;
		}
		elsif ( $content =~ s/(bugtracker\s*=>\s*\{[^}]*?)(\bweb\s*=>\s*)"[^"]*"/${1}${2}"$bugtracker_web"/s ) {
			1;
		}
	}
	elsif ( $content =~ /(resources\s*=>\s*\{)/ ) {
		my $inj = <<"BUG";
			bugtracker => {
				web => '$bugtracker_web',
			},
BUG
		$content =~ s/$1/$1\n$inj/s;
	}

	warn "[prepare4release] Makefile.PL: patched existing META_MERGE\n" if $verbose;
	return $content;
}

sub apply_makefile_patches {
	my ( $class, $makefile_path, $opts, $app, $verbose ) = @_;
	my ( $content, $snippets ) = $class->read_makefile_pl_snippets($makefile_path);

	my $want_pod2github = $opts->{github} || $opts->{gitlab};
	my $new = $class->ensure_postamble( $content, $want_pod2github, $verbose );

	my $repo_git = $app->repository_git_url;
	my $repo_web = $app->repository_web_url;
	my $bug       = $app->bugtracker_url;

	$new = $class->ensure_meta_merge( $new, $repo_git, $repo_web, $bug, $verbose );

	if ( $new ne $content ) {
		open my $out, '>:encoding(UTF-8)', $makefile_path
			or croak "Cannot write Makefile.PL '$makefile_path': $!";
		print {$out} $new;
		close $out;
		warn "[prepare4release] Makefile.PL updated: $makefile_path\n" if $verbose;
	}
	elsif ($verbose) {
		warn "[prepare4release] Makefile.PL unchanged\n";
	}
	return;
}

# --- Perl version range + MetaCPAN -------------------------------------------

sub min_perl_version_from_makefile_content {
	my ( $class, $content ) = @_;
	return unless defined $content;
	if ( $content =~ /MIN_PERL_VERSION\s*=>\s*['"]([^'"]+)['"]/ ) {
		return $1;
	}
	return;
}

sub min_perl_version_from_pm_content {
	my ( $class, $content ) = @_;
	return unless defined $content;
	my @lines = split /\n/, $content;
	for my $line (@lines) {
		next if $line =~ /^\s*#/;
		if ( $line =~ /^\s*use\s+v5\.(\d+)\.(\d+)\s*;/ ) {
			return "v5.$1.$2";
		}
		if ( $line =~ /^\s*use\s+v5\.(\d+)\s*;/ ) {
			return "v5.$1.0";
		}
		if ( $line =~ /^\s*use\s+(5\.\d+)\s*;/ ) {
			my $v = eval { version->parse($1) };
			return $v->normal if $v;
		}
		if ( $line =~ /^\s*use\s+([0-9]+\.[0-9]+)\s*;/ ) {
			my $v = eval { version->parse($1) };
			return $v->normal if $v;
		}
	}
	return;
}

sub _minor_from_version_token {
	my ( $class, $token ) = @_;
	return unless defined $token && length $token;
	$token =~ s/\s+\z//;

	# v-string forms (always unambiguous)
	if ( $token =~ /^v5\.(\d+)\./ ) {
		return 0 + $1;
	}

	# Plain dotted: 5.16, 5.15.0, 5.10.1 — minor is the first component after "5."
	if ( $token =~ /^5\.(\d+)\.(\d+)(?:\.(\d+))?\z/ ) {
		return 0 + $1;
	}
	if ( $token =~ /^5\.(\d+)\z/ ) {
		my $mant = $1;
		# Packed mantissa (e.g. 5.008007): handled by version.pm below
		if ( length($mant) <= 4 && $mant !~ /\A0\d/ ) {
			return 0 + $mant;
		}
	}

	my $v = eval { version->parse($token) };
	return unless $v;
	my $n = $v->normal;
	if ( $n =~ /^v5\.(\d+)\./ ) {
		return 0 + $1;
	}
	# Decimal normals from version.pm (e.g. 5.016000). Use 0+$1 not int($1):
	# int("016") / sprintf "%d", "010" can follow legacy octal rules on older perls.
	if ( $n =~ /^5\.(\d{3})(\d{3})\z/ ) {
		return 0 + $1;
	}
	if ( $n =~ /^5\.(\d{3})/ ) {
		return 0 + $1;
	}
	return;
}

sub resolve_combined_min_perl {
	my ( $class, $makefile_content, $pm_path ) = @_;
	my @candidates;
	if ($makefile_content) {
		my $m = $class->min_perl_version_from_makefile_content($makefile_content);
		push @candidates, $m if defined $m;
	}
	if ( $pm_path && -e $pm_path ) {
		open my $fh, '<:encoding(UTF-8)', $pm_path
			or croak "Cannot open '$pm_path': $!";
		local $/;
		my $pm = <$fh>;
		close $fh;
		my $p = $class->min_perl_version_from_pm_content($pm);
		push @candidates, $p if defined $p;
	}
	return unless @candidates;

	my $max_req;
	for my $c (@candidates) {
		my $v = eval { version->parse($c) };
		next unless $v;
		$max_req = $v if !defined $max_req || $v > $max_req;
	}
	return unless $max_req;
	return $max_req->normal;
}

sub fetch_latest_perl_release_version {
	my ($class) = @_;

	if ( defined $ENV{PREPARE4RELEASE_PERL_MAX} && length $ENV{PREPARE4RELEASE_PERL_MAX} ) {
		return $ENV{PREPARE4RELEASE_PERL_MAX};
	}

	eval { require HTTP::Tiny; 1 }
		or do {
			warn "[prepare4release] HTTP::Tiny not available; set PREPARE4RELEASE_PERL_MAX or install HTTP::Tiny\n";
			return '5.40';
		};

	my $url =
'https://fastapi.metacpan.org/v1/release/_search?q=distribution:perl&size=1&sort=version:desc';
	my $http = HTTP::Tiny->new( timeout => 25 );
	my $res  = $http->get($url);
	if ( !$res->{success} || !$res->{content} ) {
		warn "[prepare4release] MetaCPAN lookup failed; using fallback 5.40\n";
		return '5.40';
	}

	my $data = eval { JSON::PP->new->decode( $res->{content} ) };
	if ( !$data || ref $data ne 'HASH' ) {
		warn "[prepare4release] MetaCPAN JSON decode failed; using fallback 5.40\n";
		return '5.40';
	}

	my $hits = $data->{hits};
	if ( ref $hits eq 'HASH' && ref $hits->{hits} eq 'ARRAY' ) {
		$hits = $hits->{hits};
	}
	if ( ref $hits ne 'ARRAY' || !@{ $hits } ) {
		warn "[prepare4release] MetaCPAN returned no hits; using fallback 5.40\n";
		return '5.40';
	}

	my $ver = $hits->[0]{_source}{version};
	if ( defined $ver && $ver =~ /^5\.(\d+)\.(\d+)/ ) {
		return sprintf( '5.%d', $1 );
	}
	if ( defined $ver && $ver =~ /^(5\.\d+)/ ) {
		return $1;
	}
	warn "[prepare4release] Unexpected MetaCPAN version '$ver'; using fallback 5.40\n";
	return '5.40';
}

sub perl_matrix_tags {
	my ( $class, $min_token, $max_token ) = @_;
	my $min_m = $class->_minor_from_version_token($min_token);
	my $max_m = $class->_minor_from_version_token($max_token);
	return () unless defined $min_m && defined $max_m;

	my $start = $min_m;
	$start++ if $start % 2;
	my $end = $max_m;
	$end-- if $end % 2;
	return () if $start > $end;

	my @tags;
	for ( my $m = $start ; $m <= $end ; $m += 2 ) {
		push @tags, sprintf( '5.%d', $m );
	}
	return @tags;
}

sub ci_apt_packages {
	my ( $class, $config ) = @_;
	$config = {} unless ref $config eq 'HASH';
	my $ci = $config->{ci};
	return () unless ref $ci eq 'HASH';
	my $apt = $ci->{apt_packages};
	return () unless ref $apt eq 'ARRAY';
	return grep { defined && length } @{$apt};
}

sub scan_files_for_alien_hints {
	my ( $class, $cwd ) = @_;
	my @texts;
	for my $f (qw(Makefile.PL cpanfile Build.PL)) {
		my $p = File::Spec->catfile( $cwd, $f );
		next unless -e $p;
		open my $fh, '<:encoding(UTF-8)', $p or next;
		local $/;
		push @texts, ( <$fh> // '' );
		close $fh;
	}
	my $blob = join "\n", @texts;
	my %seen;
	while ( $blob =~ /\bAlien::([A-Za-z0-9_:]+)/g ) {
		$seen{$1} = 1;
	}
	return sort keys %seen;
}

sub render_github_ci_yml {
	my ( $class, $perl_versions, $apt_packages ) = @_;
	my @perl = ref $perl_versions eq 'ARRAY' ? @{$perl_versions} : ();
	my @apt  = ref $apt_packages   eq 'ARRAY' ? @{$apt_packages}   : ();

	my $matrix = join ', ', map { qq{'$_'} } @perl;
	my $apt_yaml = '';
	if (@apt) {
		my $list = join ' ', @apt;
		$apt_yaml = <<"APT";

      - name: Install system packages (apt)
        run: sudo apt-get update && sudo apt-get install -y $list
APT
	}

	return <<"YML";
# Generated by App::prepare4release -- matrix from MIN_PERL_VERSION / use v5.x and latest stable from MetaCPAN
name: CI

on:
  push:
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        perl-version: [$matrix]

    steps:
      - uses: actions/checkout\@v4

      - name: Set up Perl
        uses: shivammathur/setup-perl\@v2
        with:
          perl-version: \${{ matrix.perl-version }}
$apt_yaml
      - name: Install dependencies (cpanm)
        run: |
          curl -sL https://cpanmin.us | perl - App::cpanminus
          cpanm --notest --with-develop --installdeps .

      - name: Run tests
        run: prove -lr t
YML
}

sub render_gitlab_ci_yml {
	my ( $class, $perl_versions, $apt_packages ) = @_;
	my @perl = ref $perl_versions eq 'ARRAY' ? @{$perl_versions} : ();
	my @apt  = ref $apt_packages   eq 'ARRAY' ? @{$apt_packages}   : ();

	my $matrix_list = join ', ', map { qq{'$_'} } @perl;

	my $apt_lines = '';
	if (@apt) {
		my $list = join ' ', @apt;
		$apt_lines = "    - apt-get install -y -qq $list\n";
	}

	return <<"YML";
# Generated by App::prepare4release -- matrix from MIN_PERL_VERSION / use v5.x and latest stable from MetaCPAN
stages:
  - test

test:
  stage: test
  parallel:
    matrix:
      - PERL_VERSION: [$matrix_list]
  image: perl:\${PERL_VERSION}
  before_script:
    - apt-get update -qq
$apt_lines    - curl -sL https://cpanmin.us | perl - App::cpanminus
    - cpanm --notest --with-develop --installdeps .
  script:
    - prove -lr t
YML
}

sub ensure_github_workflow {
	my ( $class, $root, $yaml, $verbose ) = @_;
	my $dir = File::Spec->catfile( $root, '.github', 'workflows' );
	my $path = File::Spec->catfile( $dir, 'ci.yml' );
	if ( -e $path ) {
		warn "[prepare4release] $path already exists, skipping\n" if $verbose;
		return;
	}
	make_path($dir);
	open my $out, '>:encoding(UTF-8)', $path
		or croak "Cannot write $path: $!";
	print {$out} $yaml;
	close $out;
	warn "[prepare4release] wrote $path\n" if $verbose;
	return;
}

sub ensure_gitlab_ci {
	my ( $class, $root, $yaml, $verbose ) = @_;
	my $path = File::Spec->catfile( $root, '.gitlab-ci.yml' );
	if ( -e $path ) {
		warn "[prepare4release] $path already exists, skipping\n" if $verbose;
		return;
	}
	open my $out, '>:encoding(UTF-8)', $path
		or croak "Cannot write $path: $!";
	print {$out} $yaml;
	close $out;
	warn "[prepare4release] wrote $path\n" if $verbose;
	return;
}

sub apply_ci_files {
	my ( $class, $cwd, $opts, $config, $makefile_content, $identity, $verbose ) = @_;

	my $min = $class->resolve_combined_min_perl( $makefile_content,
		$identity->{version_from_path} );
	if ( !$min ) {
		$min = 'v5.10.0';
		warn "[prepare4release] no MIN_PERL_VERSION/use v5 found; assuming v5.10.0 as matrix floor\n"
			if $verbose;
	}

	my $max = $class->fetch_latest_perl_release_version;
	my @matrix = $class->perl_matrix_tags( $min, $max );
	if ( !@matrix ) {
		warn "[prepare4release] empty Perl matrix; skipping CI file generation\n";
		return;
	}

	if ($verbose) {
		warn "[prepare4release] Perl CI matrix: " . join( ', ', @matrix ) . "\n";
		my @alien = $class->scan_files_for_alien_hints($cwd);
		if (@alien) {
			warn "[prepare4release] Alien::* modules seen in Makefile.PL/cpanfile: "
				. join( ', ', @alien )
				. " -- add ci.apt_packages in prepare4release.json if system libs are needed\n";
		}
	}

	my $apt = [ $class->ci_apt_packages($config) ];

	if ( $opts->{github} ) {
		my $yml = $class->render_github_ci_yml( \@matrix, $apt );
		$class->ensure_github_workflow( $cwd, $yml, $verbose );
	}

	if ( $opts->{gitlab} ) {
		my $yml = $class->render_gitlab_ci_yml( \@matrix, $apt );
		$class->ensure_gitlab_ci( $cwd, $yml, $verbose );
	}

	return;
}

# --- POD badges + xt/author -------------------------------------------------

sub _uri_escape_path {
	my ($s) = @_;
	$s =~ s/([^A-Za-z0-9_.~-])/sprintf( '%%%02X', ord($1) )/eg;
	return $s;
}

sub cpan_dist_name_from_identity {
	my ( $class, $identity ) = @_;
	my $d = $identity->{dist_name};
	return $d if defined $d && length $d;
	my $m = $identity->{module_name};
	croak 'dist_name / module_name required' unless defined $m && length $m;
	( my $copy = $m ) =~ s/::/-/g;
	return $copy;
}

sub repology_metacpan_badge_url {
	my ( $class, $dist ) = @_;
	my $slug = lc $dist;
	$slug =~ s/\s+/-/g;
	my $pkg = 'perl:' . $slug;
	my $enc = _uri_escape_path($pkg);
	return "https://repology.org/badge/version-for-repo/metacpan/$enc.svg";
}

sub license_badge_info {
	my ( $class, $license_key ) = @_;
	$license_key = 'perl' unless defined $license_key && length $license_key;
	my %h = (
		perl    => [ 'Perl%205', 'https://dev.perl.org/licenses/' ],
		perl_5  => [ 'Perl%205', 'https://dev.perl.org/licenses/' ],
		apache_2 =>
			[ 'Apache%202.0', 'https://www.apache.org/licenses/LICENSE-2.0' ],
		artistic_2 =>
			[ 'Artistic%202.0', 'https://opensource.org/licenses/Artistic-2.0' ],
		mit => [ 'MIT', 'https://opensource.org/licenses/MIT' ],
		gpl_3 => [ 'GPL%203', 'https://www.gnu.org/licenses/gpl-3.0.html' ],
		lgpl_3 =>
			[ 'LGPL%203', 'https://www.gnu.org/licenses/lgpl-3.0.html' ],
		bsd => [ 'BSD%203--Clause', 'https://opensource.org/licenses/BSD-3-Clause' ],
	);
	if ( my $p = $h{$license_key} ) {
		return @{$p};
	}
	( 'License', 'https://opensource.org/licenses/' );
}

sub perl_min_badge_label {
	my ( $class, $min_normal ) = @_;
	return '5.10%2B' unless defined $min_normal && length $min_normal;
	my $v = eval { version->parse($min_normal) };
	return '5.10%2B' unless $v;
	my $n = $v->normal;
	return '5.10%2B' unless $n =~ /^v5\.(\d+)/;
	my $minor = $1;
	return _uri_escape_path("5.$minor+");
}

sub build_pod_badge_html {
	my ( $class, $app, $opts, $cpan, $mf_snippets, $identity, $min_normal )
		= @_;

	my $dist = $class->cpan_dist_name_from_identity($identity);
	my $mod  = $identity->{module_name};
	my $mod_url = $mod;
	$mod_url =~ s/::/\//g;

	my ( $lic_label, $lic_href ) = $class->license_badge_info( $mf_snippets->{license} );
	my $perl_lbl = $class->perl_min_badge_label($min_normal);

	my @rows;

	push @rows,
		qq{<a href="$lic_href"><img src="https://img.shields.io/badge/license-$lic_label-blue.svg" alt="License" /></a>};

	push @rows,
		qq{<a href="https://www.perl.org/"><img src="https://img.shields.io/badge/perl-$perl_lbl-blue.svg" alt="Perl" /></a>};

	my $author = __PACKAGE__->git_author( $app->{config} // {} );
	my $repo   = $app->module_repo;
	my $host   = __PACKAGE__->effective_git_host( $opts, $app->{config} // {} );

	if ( $host eq 'github.com' ) {
		my $ci_img =
"https://github.com/$author/$repo/actions/workflows/ci.yml/badge.svg";
		my $ci_url =
"https://github.com/$author/$repo/actions/workflows/ci.yml";
		push @rows,
			qq{<a href="$ci_url"><img src="$ci_img" alt="CI" /></a>};
	}
	else {
		my $web = $app->repository_web_url;
		my $pipe = "$web/badges/main/pipeline.svg";
		my $ci_url = "$web/-/pipelines";
		push @rows,
			qq{<a href="$ci_url"><img src="$pipe" alt="CI" /></a>};
	}

	if ($cpan) {
		my $rep_b = $class->repology_metacpan_badge_url($dist);
		my $rep_l = "https://repology.org/project/perl%3A"
			. _uri_escape_path( lc $dist ) . '/versions';
		push @rows,
			qq{<a href="$rep_l"><img src="$rep_b" alt="MetaCPAN package" /></a>};

		my $fury = "https://badge.fury.io/pl/$dist.svg";
		my $meta = "https://metacpan.org/pod/$mod_url";
		push @rows,
			qq{<a href="$meta"><img src="$fury" alt="CPAN version" /></a>};

		my $cpants = "https://cpants.cpanauthors.org/dist/$dist.svg";
		my $cpants_l = "https://cpants.cpanauthors.org/dist/$dist";
		push @rows,
			qq{<a href="$cpants_l"><img src="$cpants" alt="CPAN testers" /></a>};
	}

	my $inner = join "\n", map { "<p>$_</p>" } @rows;
	return $inner;
}

sub split_pm_code_and_pod {
	my ( $class, $path ) = @_;
	open my $fh, '<:encoding(UTF-8)', $path
		or croak "Cannot open '$path': $!";
	local $/;
	my $all = <$fh> // '';
	close $fh;

	if ( $all =~ /\n__END__\s*\r?\n(.*)\z/s ) {
		my $code = $`;
		return ( $code, $1 );
	}
	return ( $all, '' );
}

sub inject_pod_badges_block {
	my ( $class, $pod, $inner_html ) = @_;

	# Build POD without a heredoc: lines starting with "=" at column 0 in this file
	# are parsed as POD by Test::Pod and break "=begin html" / "=end html" pairing.
	my $block = join "\n",
		'=begin html',
		'',
		'<!-- PREPARE4RELEASE_BADGES -->',
		$inner_html,
		'<!-- /PREPARE4RELEASE_BADGES -->',
		'',
		'=end html',
		'';

	if ( $pod =~ /<!-- PREPARE4RELEASE_BADGES -->/s ) {
		$pod =~ s{
			=begin\s+html\s*\n
			\s*<!--\s*PREPARE4RELEASE_BADGES\s*-->\s*
			.*?
			<!--\s*/PREPARE4RELEASE_BADGES\s*-->\s*
			\n\s*=end\s+html
		}{$block}six;
		return $pod;
	}

	if ( $pod =~ s/(=head1\s+NAME\s*\n\n.+?)(\n\n=head1\s+)/$1\n\n$block$2/s ) {
		return $pod;
	}

	return $block . "\n\n" . $pod;
}

sub apply_pod_badges {
	my ( $class, $cwd, $opts, $app, $mf_content, $mf_snippets, $identity,
		$verbose )
		= @_;

	my $vf = $identity->{version_from_path};
	if ( !$vf || !-e $vf ) {
		warn "[prepare4release] no VERSION_FROM path; skipping POD badges\n"
			if $verbose;
		return;
	}

	my $min = $class->resolve_combined_min_perl( $mf_content, $vf );
	$min = 'v5.10.0' unless defined $min && length $min;

	my $inner = $class->build_pod_badge_html(
		$app, $opts, $opts->{cpan} ? 1 : 0,
		$mf_snippets, $identity, $min
	);

	my ( $code, $pod ) = $class->split_pm_code_and_pod($vf);
	if ( !length $pod ) {
		warn "[prepare4release] no POD after __END__ in $vf; skipping badges\n"
			if $verbose;
		return;
	}

	my $new_pod = $class->inject_pod_badges_block( $pod, $inner );
	return if $new_pod eq $pod;

	my $out = $code . "\n__END__\n" . $new_pod;
	open my $out_fh, '>:encoding(UTF-8)', $vf
		or croak "Cannot write '$vf': $!";
	print {$out_fh} $out;
	close $out_fh;
	warn "[prepare4release] updated POD badges in $vf\n" if $verbose;
	return;
}

sub list_files_for_eol_xt {
	my ( $class, $cwd ) = @_;
	my @out;

	for my $f (qw(Makefile.PL Build.PL cpanfile prepare4release.json)) {
		my $p = File::Spec->catfile( $cwd, $f );
		push @out, $f if -f $p;
	}

	push @out, map { File::Spec->abs2rel( $_, $cwd ) }
		$class->find_lib_pm_files($cwd);

	my $bin = File::Spec->catfile( $cwd, 'bin' );
	if ( -d $bin ) {
		opendir my $dh, $bin or croak "opendir bin: $!";
		while ( my $e = readdir $dh ) {
			next if $e =~ /^\./;
			my $rel = File::Spec->catfile( 'bin', $e );
			push @out, $rel if -f File::Spec->catfile( $cwd, $rel );
		}
		closedir $dh;
	}

	for my $td (qw(t xt)) {
		my $root = File::Spec->catfile( $cwd, $td );
		next unless -d $root;
		File::Find::find(
			{
				no_chdir => 1,
				wanted   => sub {
					return unless -f;
					return unless $File::Find::name =~ /\.(t|pm|pl)\z/;
					push @out, File::Spec->abs2rel( $File::Find::name, $cwd );
				},
			},
			$root
		);
	}

	my %seen;
	@out = grep { !$seen{$_}++ } sort @out;
	return @out;
}

sub ensure_xt_author_tests {
	my ( $class, $cwd, $verbose ) = @_;

	my $xtd = File::Spec->catfile( $cwd, 'xt', 'author' );
	make_path($xtd);

	my $pod_xt = File::Spec->catfile( $xtd, 'pod.t' );
	if ( !-e $pod_xt ) {
		my $body = <<'XT';
#!perl
use strict;
use warnings;
use Test2::V1;
use Test2::Tools::Basic qw(skip_all);

BEGIN {
	eval {
		require Test::Pod;
		Test::Pod->import;
		1;
	} or skip_all 'Test::Pod is required for author tests';
}

all_pod_files_ok();
XT
		$class->_write_if_absent( $pod_xt, $body, $verbose );
	}

	my $pc_xt = File::Spec->catfile( $xtd, 'pod-coverage.t' );
	if ( !-e $pc_xt ) {
		my $body = <<'XT';
#!perl
use strict;
use warnings;
use Test2::V1;
use Test2::Tools::Basic qw(skip_all);

BEGIN {
	eval {
		require Test::Pod::Coverage;
		Test::Pod::Coverage->import;
		1;
	} or skip_all 'Test::Pod::Coverage is required for author tests';
}

all_pod_coverage_ok();
XT
		$class->_write_if_absent( $pc_xt, $body, $verbose );
	}

	my @eol = $class->list_files_for_eol_xt($cwd);
	my $eol_xt = File::Spec->catfile( $xtd, 'eol.t' );
	if ( !-e $eol_xt ) {
		my $list = join "\n", map { '    ' . $_ } @eol;
		my $head = <<'EOL_HEAD';
#!perl
use strict;
use warnings;
use Test2::V1;
use Test2::Tools::Basic qw(skip_all done_testing);

BEGIN {
	eval {
		require Test::EOL;
		Test::EOL->import;
		1;
	} or skip_all 'Test::EOL is required for author tests';
}

my @files = qw(
EOL_HEAD
		my $tail = <<'EOL_TAIL';
);

eol_unix_ok($_) for @files;

done_testing;
EOL_TAIL
		my $body = $head . $list . $tail;
		$class->_write_if_absent( $eol_xt, $body, $verbose );
	}

	return;
}

sub _write_if_absent {
	my ( $class, $path, $body, $verbose ) = @_;
	open my $fh, '>:encoding(UTF-8)', $path
		or croak "Cannot write '$path': $!";
	print {$fh} $body;
	close $fh;
	warn "[prepare4release] wrote $path\n" if $verbose;
	return;
}

sub _collect_t_files {
	my ( $class, $cwd ) = @_;
	my @out;
	for my $root_name (qw(t xt)) {
		my $root = File::Spec->catfile( $cwd, $root_name );
		next unless -d $root;
		File::Find::find(
			{
				no_chdir => 1,
				wanted   => sub {
					return unless -f && /\.t\z/;
					push @out, File::Spec->abs2rel( $File::Find::name, $cwd );
				},
			},
			$root
		);
	}
	my %seen;
	@out = grep { !$seen{$_}++ } sort @out;
	return @out;
}

sub file_uses_legacy_assertion_framework {
	my ( $class, $path ) = @_;
	open my $fh, '<:encoding(UTF-8)', $path
		or return 0;
	while ( my $line = <$fh> ) {
		next if $line =~ /^\s*#/;
		next if $line =~ /^\s*=/;
		return 1 if $line =~ /^\s*use\s+Test::More\b/;
		return 1 if $line =~ /^\s*use\s+Test::Most\b/;
	}
	close $fh;
	return 0;
}

sub warn_legacy_test_frameworks {
	my ( $class, $cwd ) = @_;
	my @bad;
	for my $rel ( $class->_collect_t_files($cwd) ) {
		my $abs = File::Spec->catfile( $cwd, $rel );
		next unless -f $abs;
		next unless $class->file_uses_legacy_assertion_framework($abs);
		push @bad, $rel;
	}
	return unless @bad;

	warn "[prepare4release] These test files appear to use a legacy assertion "
		. "framework (Test::More or Test::More-style Test::Most) instead of "
		. "Test2::*. Consider migrating to Test2::V1 or Test2::Tools::Spec. "
		. "Files: "
		. join( ', ', @bad )
		. "\n";
	return;
}

# --- Config load -------------------------------------------------------------

sub load_config_file {
	my ( $class, $path ) = @_;
	open my $fh, '<:encoding(UTF-8)', $path
		or croak "Cannot open '$path': $!";
	local $/;
	my $raw = <$fh>;
	close $fh;
	my $json = JSON::PP->new->relaxed;
	my $data = $json->decode($raw);
	croak 'prepare4release.json must be a JSON object'
		unless ref $data eq 'HASH';
	return $data;
}

sub resolve_config_path {
	my ( $class, $explicit ) = @_;
	return $explicit if defined $explicit && length $explicit;
	my $cwd = getcwd();
	return File::Spec->catfile( $cwd, $class->DEFAULT_CONFIG_FILENAME );
}

sub parse_argv {
	my ( $class, $argv ) = @_;
	$argv = [@ARGV] unless defined $argv;

	require Getopt::Long;
	Getopt::Long::Configure(qw(bundling no_ignore_case));

	my %opts;
	my $pod = $class->_pod_input_file;
	Getopt::Long::GetOptionsFromArray(
		$argv,
		'github'   => \$opts{github},
		'gitlab'   => \$opts{gitlab},
		'cpan'     => \$opts{cpan},
		'help|?'   => \$opts{help},
		'usage'    => \$opts{usage},
		'verbose'  => \$opts{verbose},
	) or pod2usage( -verbose => 0, -exitval => 2, -input => $pod );

	if ( $opts{help} ) {
		pod2usage( -verbose => 2, -input => $pod );
	}
	if ( $opts{usage} ) {
		pod2usage( -verbose => 0, -input => $pod );
	}

	if ( $opts{github} && $opts{gitlab} ) {
		croak 'Use only one of --github or --gitlab';
	}

	return \%opts;
}

sub _pod_input_file {
	require FindBin;
	return File::Spec->rel2abs( $FindBin::Script, $FindBin::RealBin );
}

sub run {
	my ( $class, @argv ) = @_;
	my $opts = $class->parse_argv( \@argv );

	my $config_path = $class->resolve_config_path;
	-e $config_path
		or croak "Expected config file in current directory: $config_path";

	my $config = $class->load_config_file($config_path);
	my $cwd    = getcwd();

	my $mf = $class->makefile_pl_path;
	croak 'Makefile.PL not found in current directory' unless $mf;

	my ( $mf_content, $mf_snippets ) = $class->read_makefile_pl_snippets($mf);
	my $identity = $class->resolve_identity( $cwd, $config, $mf_snippets );

	my $app = $class->new(
		config_path => $config_path,
		config      => $config,
		opts        => $opts,
		identity    => $identity,
	);

	croak 'Could not resolve module_name (set module_name in prepare4release.json, or fix Makefile.PL VERSION_FROM / lib/)'
		unless $identity->{module_name};
	croak 'git.author is required in prepare4release.json under "git"'
		unless $class->git_author($config);

	$class->warn_legacy_test_frameworks($cwd);

	if ( $opts->{verbose} ) {
		require Data::Dumper;
		local $Data::Dumper::Sortkeys = 1;
		warn "[prepare4release] config path: $config_path\n";
		warn "[prepare4release] options: "
			. Data::Dumper::Dumper($opts);
		warn "[prepare4release] config: "
			. Data::Dumper::Dumper($config);
		warn "[prepare4release] identity: "
			. Data::Dumper::Dumper($identity);
		warn "[prepare4release] git host: "
			. $class->effective_git_host( $opts, $config ) . "\n";
		warn "[prepare4release] repository web: " . $app->repository_web_url . "\n";
		warn "[prepare4release] repository git: " . $app->repository_git_url . "\n";
		warn "[prepare4release] bugtracker: " . $app->bugtracker_url . "\n";
	}

	$class->apply_makefile_patches( $mf, $opts, $app, $opts->{verbose} );

	if ( $opts->{github} || $opts->{gitlab} ) {
		$class->apply_ci_files(
			$cwd, $opts, $config, $mf_content, $identity,
			$opts->{verbose}
		);
	}

	$class->apply_pod_badges(
		$cwd, $opts, $app, $mf_content, $mf_snippets, $identity,
		$opts->{verbose}
	);

	$class->ensure_xt_author_tests( $cwd, $opts->{verbose} );

	return 0;
}

1;

__END__

=encoding UTF-8

=head1 NAME

App::prepare4release - prepare a Perl distribution for release (skeleton)

=head1 SYNOPSIS

  use App::prepare4release;
  App::prepare4release->run(@ARGV);

=head1 DESCRIPTION

Run from the distribution root (where F<prepare4release.json> and F<Makefile.PL>
live). The tool:

=over 4

=item *

Loads F<prepare4release.json> and resolves C<module_name> / C<version> / C<dist_name>
when omitted (from F<Makefile.PL> and the main F<.pm>).

=item *

Patches F<Makefile.PL>: C<MY::postamble> (C<pod2github> when C<--github> or
C<--gitlab>, else C<pod2markdown>) and C<META_MERGE> (C<repository> and
C<bugtracker> URLs).

=item *

When C<--github> or C<--gitlab> is set, ensures CI workflow files exist (see
L</Continuous integration>).

=item *

Injects an HTML badge block into the F<VERSION_FROM> module's POD (between
C<=head1 NAME> and the next C<=head1>, or updates an existing block delimited by
C<PREPARE4RELEASE_BADGES> comments). Always adds license, minimum Perl, and CI
badges; with C<--cpan>, also adds Repology / MetaCPAN, CPAN version (fury.io),
and CPAN testers (cpants) badges. License text follows F<Makefile.PL>
C<LICENSE> when mapped; otherwise a generic L<Open Source Initiative|https://opensource.org/licenses/>
link.

=item *

Creates author tests under F<xt/author/> when missing: C<pod.t> (L<Test::Pod>),
C<eol.t> (L<Test::EOL>), C<pod-coverage.t> (L<Test::Pod::Coverage>), using
L<Test2::V1>.

=item *

Warns when any F<t/*.t> or F<xt/**/*.t> file starts with C<use Test::More> or
C<use Test::Most> (legacy assertion frameworks). Prefer L<Test2::V1> or
L<Test2::Tools::Spec>.

=back

=head1 CONFIGURATION FILE

File name: F<prepare4release.json> (in the distribution root).

=over 4

=item C<module_name>

Optional. Perl package (e.g. C<My::Module>). If omitted, taken from the
C<VERSION_FROM> module's C<package> line, from C<NAME> in F<Makefile.PL>, or from
the first C<lib/**/*.pm> file.

=item C<version>

Optional. If omitted, taken from C<$VERSION> in the resolved main module file.

=item C<dist_name>

Optional. Defaults to C<module_name> with C<::> replaced by hyphens.

=item C<bugtracker>

Optional bugtracker URL. If omitted, it is built as
C<< <repository web>/issues >> for the selected git host.

=item C<git>

Object (optional) with:

=over 8

=item C<author>

Required for repository URLs. GitHub / GitLab user or group (path segment before
the repository name).

=item C<repo>

Repository name. If omitted, defaults to C<perl-> plus C<module_name> with
C<::> replaced by hyphens.

=item C<server>

Optional hostname (e.g. C<gitlab.example.com>) for C<https://> links instead of
C<github.com> / C<gitlab.com>.

=back

=item C<ci>

Optional object:

=over 8

=item C<apt_packages>

Array of Debian package names (e.g. C<libssl-dev>) appended to the generated
GitHub Actions and GitLab CI C<apt-get install> steps. System libraries are not
inferrable reliably from CPAN metadata alone; list them here when XS or
C<Alien::*> needs OS packages.

=back

=back

=head1 Continuous integration

When C<--github> is set, if F<.github/workflows/ci.yml> does not exist it is
created. It runs C<prove -lr t> on an Ubuntu runner using
L<https://github.com/shivammathur/setup-perl|shivammathur/setup-perl>, with a
matrix of stable Perl releases from the stricter of F<Makefile.PL>
C<MIN_PERL_VERSION> and the main module's C<use v5...> / C<use 5...> line, up
to the latest stable Perl.

The ceiling is resolved at each run via the MetaCPAN API (distribution
C<perl>, newest release). If the request fails, a fallback (currently C<5.40>)
is used. Override for tests or air-gapped use:

  PREPARE4RELEASE_PERL_MAX=5.40 prepare4release ...

Matrix entries use even minor versions only (C<5.10>, C<5.12>, …) between the
computed minimum and maximum.

When C<--gitlab> is set, if F<.gitlab-ci.yml> is missing it is created with a
C<parallel.matrix> over C<PERL_VERSION> and the official C<perl> Docker image.

Existing workflow files are never overwritten.

=head1 System dependencies (apt)

There is no robust automatic mapping from CPAN modules to Debian packages. The
tool scans F<Makefile.PL>, F<cpanfile>, and F<Build.PL> for C<Alien::...> names
and, with C<--verbose>, warns so you can add C<ci.apt_packages> manually.

=head1 ENVIRONMENT

=over 4

=item C<PREPARE4RELEASE_PERL_MAX>

If set, used as the matrix ceiling instead of querying MetaCPAN (useful for CI
of this tool or offline work).

=item C<RELEASE_TESTING>

If set to a true value, author tests under F<xt/> may run (see
F<xt/metacpan-live.t> for a live MetaCPAN request that validates
C<fetch_latest_perl_release_version>).

=back

=head1 COPYRIGHT AND LICENSE

Copyright (C) by the authors.

Same terms as Perl 5 itself.

=cut
