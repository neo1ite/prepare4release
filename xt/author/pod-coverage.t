#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

BEGIN {
	my $ok = eval { require Test::Pod::Coverage; 1 };
	$ok
		or plan skip_all =>
		'Test::Pod::Coverage is required for author tests ($^X): '
		. ( $@ || 'unknown error' );
}

# Pod::Coverage does not reliably honor "=for Pod::Coverage" in all installs;
# trustme marks these as documented for coverage purposes.
# Call by package name: import(qw(pod_coverage_ok)) is forwarded to Test::More::plan and breaks.
Test::Pod::Coverage::pod_coverage_ok(
	'App::prepare4release',
	{
		trustme => [
			qw(
				DEFAULT_CONFIG_FILENAME
				POSTAMBLE_POD2GITHUB
				POSTAMBLE_POD2MARKDOWN
				apply_ci_files
				apply_makefile_patches
				apply_pod_badges
				bugtracker_url
				build_pod_badge_html
				ci_apt_packages
				cpan_dist_name_from_identity
				effective_git_host
				ensure_github_workflow
				ensure_gitlab_ci
				ensure_meta_merge
				ensure_postamble
				ensure_xt_author_tests
				fetch_latest_perl_release_version
				file_uses_legacy_assertion_framework
				find_lib_pm_files
				git_author
				git_hash
				git_repo_name
				git_server
				https_base
				inject_pod_badges_block
				license_badge_info
				list_files_for_eol_xt
				load_config_file
				makefile_has_pod2github
				makefile_has_pod2markdown
				makefile_pl_path
				meta_merge_block
				min_perl_version_from_makefile_content
				min_perl_version_from_pm_content
				module_repo
				new
				package_to_repo_default
				parse_argv
				parse_pm_identity
				perl_matrix_tags
				perl_min_badge_label
				read_makefile_pl_snippets
				render_github_ci_yml
				render_gitlab_ci_yml
				repology_metacpan_badge_url
				repository_git_url
				repository_path_segment
				repository_web_url
				resolve_combined_min_perl
				resolve_config_path
				resolve_identity
				run
				scan_files_for_alien_hints
				split_pm_code_and_pod
				warn_legacy_test_frameworks
				write_makefile_close_index
			)
		],
		also_private => [
			qr/^_/,
		],
	},
);

done_testing;
