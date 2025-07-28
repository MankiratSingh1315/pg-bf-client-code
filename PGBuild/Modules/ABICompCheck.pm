# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2024, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::Skeleton;
use PGBuild::Log;
use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils qw(:DEFAULT $branch_root);

use strict;
use warnings;
use File::Path 'mkpath';
use File::Copy;
use Cwd qw(abs_path getcwd);


# strip required namespace from package name
(my $MODULE = __PACKAGE__) =~ s/PGBuild::Modules:://;

our ($VERSION); $VERSION = 'REL_19_1';

my $hooks = {
	'need-run' => \&need_run,
	'install' => \&install,
	'cleanup' => \&cleanup,
};

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch = shift;       # The branch of Postgres that's being built.
	my $conf = shift;         # ref to the whole config object
	my $pgsql = shift;        # postgres build dir

	# We are only testing HEAD and stable branches, so ignore all others.
	return if $branch ne 'HEAD' && $branch !~ /_STABLE$/;
	print $buildroot, " ", $branch, " ", $conf, " ", $pgsql, "\n" if $verbose;

	my $abi_compare_root =
	  $conf->{abi_compare_root} || "$buildroot/abicheck.$conf->{animal}";
	if (   !defined($conf->{abi_compare_root})
		&& !-d $abi_compare_root
		&& -d "$buildroot/abicheck/HEAD")
	{
		# support legacy use without animal name
		$abi_compare_root = "$buildroot/abicheck";
	}

	my $binaries_rel_path = $conf->{abi_comp_check}->{binaries_rel_path}
	  || {
		'postgres' => 'bin/postgres',
		'ecpg' => 'bin/ecpg',
		'libpq.so' => 'lib/libpq.so',
	  };

	my $abidw_flags_list = $conf->{abi_comp_check}->{abidw_flags_list}
	  || [
		'--drop-undefined-syms', '--no-architecture', '--no-comp-dir-path',
		'--no-elf-needed', '--no-show-locs', '--type-id-style',
		'hash',
	  ];

	mkdir $abi_compare_root
	  unless -d $abi_compare_root;

	# we need to segregate from-source builds so they don't corrupt
	# non-from-source saves

	# my $fs_abi_compare_root = "$buildroot/fs-upgrade.$animal";

	# mkdir $fs_abi_compare_root
	#   if $from_source && !-d $fs_abi_compare_root;

	# could even set up several of these (e.g. for different branches)
	my $self = {
		buildroot => $buildroot,
		pgbranch => $branch,
		bfconf => $conf,
		pgsql => $pgsql,
		abi_compare_root => $abi_compare_root,
		# fs_abi_compare_root => $fs_abi_compare_root,
	};
	bless($self, $class);

	# for each instance you create, do:
	register_module_hooks($self, $hooks);
	return;
}

sub need_run
{
	my $self = shift;
	my $run_needed = shift;    # ref to flag
	print(Cwd::cwd());
	my $abi_compare_loc = "$self->{abi_compare_root}/$self->{pgbranch}";


	print time_str(), "checking if run needed by ", __PACKAGE__, "\n"
	  if $verbose;
	return;
}

sub install
{
	my $self = shift;
	return unless step_wanted('abi_comp-check');

	print time_str(), "install", __PACKAGE__, "\n"
	  if $verbose;
	my $scm = PGBuild::SCM->new($self->{bfconf});

	my $abi_compare_root = $self->{abi_compare_root};
	my $pgbranch         = $self->{pgbranch};
	my $abi_compare_loc  = "$abi_compare_root/$pgbranch";
	mkdir $abi_compare_loc unless -d $abi_compare_loc;

	my $latest_tag = run_log(qq{git -C ./pgsql describe --tags --abbrev=0});
	chomp $latest_tag;
	my $tag_build_dir = "$abi_compare_loc/$latest_tag";
	my $tag_inst_dir  = "$tag_build_dir/inst";
	my $tag_log_dir   = "$tag_build_dir/build_logs";

	mkpath([$tag_build_dir, $tag_inst_dir, $tag_log_dir]);

	# run_log(qq{git -C ./pgsql checkout $latest_tag});
	$scm->checkout($latest_tag, "$tag_build_dir/pgsql"); # I tried to do this but this fails by saying "Missing checked out branch bf_REL_18_BETA1:"

	# got this git save peice of code from PGBuild::SCM::Git::copy_source
	# move "./pgsql/.git", "./git-save";
	# PGBuild::SCM::copy_source($self->{bfconf}->{using_msvc},"./pgsql", "$tag_build_dir/pgsql");
	# move "./git-save", "./pgsql/.git";
	# now run the build steps
	# chdir "$tag_build_dir/pgsql";
	$self->configure($tag_inst_dir);
	$self->make();
	$self->make_install($tag_inst_dir);
	# print($branch_root);
	# chdir $branch_root;
	# # finally restore the original branch
	# run_log(qq{git -C ./pgsql checkout bf_$pgbranch});

	return;
}

sub meson_setup
{
	my $self = shift;
	my $installdir = shift;
	my $env = $self->{bfconf}->{config_env};
	$env = {%$env};                      # clone it
	delete $env->{CC} if $self->{bfconf}->{using_msvc};    # this can confuse meson in this case
	local %ENV = (%ENV, %$env);
	$ENV{MSYS2_ARG_CONV_EXCL} = "-Dextra";

	my $meson_opts = $self->{bfconf}->{meson_opts} || [];
	my @quoted_opts;
	foreach my $c_opt (@$meson_opts)
	{
		if ($c_opt =~ /['"]/)
		{
			push(@quoted_opts, $c_opt);
		}
		elsif ($self->{bfconf}->{using_msvc})
		{
			push(@quoted_opts, qq{"$c_opt"});
		}
		else
		{
			push(@quoted_opts, "'$c_opt'");
		}
	}

	my $docs_opts = "";
	$docs_opts = "-Ddocs=enabled"
	  if defined($self->{bfconf}->{optional_steps}->{build_docs});
	$docs_opts .= " -Ddocs_pdf=enabled"
	  if $docs_opts && ($self->{bfconf}->{extra_doc_targets} || "") =~ /[.]pdf/;

	my $confstr = join(" ",
		"-Dauto_features=disabled", @quoted_opts, $docs_opts, "-Dlibdir=lib",
		qq{-Dprefix="$installdir"});

	my $srcdir = $self->{bfconf}->{from_source} || 'pgsql';
	my $pgsql = $self->{pgsql};

	# use default ninja backend on all platforms
	my @confout = run_log("meson setup $confstr $pgsql $srcdir");

	my $status = $? >> 8;

	move "$pgsql/meson-logs/meson-log.txt", "$pgsql/meson-logs/setup.log";

	my $log = PGBuild::Log->new("setup");
	foreach my $logfile ("$pgsql/meson-logs/setup.log",
						 "$pgsql/src/include/pg_config.h")
	{
		$log->add_log($logfile) if -s $logfile;
	}
	push(@confout, $log->log_string);

	print "======== setup output ===========\n", @confout
	  if ($verbose > 1);

	writelog('configure', \@confout);

	# if ($status)
	# {
	# 	send_result('Configure', $status, \@confout);
	# }

	return;
}

# non-meson MSVC setup
sub msvc_setup
{
	my $self = shift;
	my $config_opts = $self->{bfconf}->{config_opts} || {};
	my $lconfig = { %$config_opts };
	my $conf = Data::Dumper->Dump([$lconfig], ['config']);
	my @text = (
		"# Configuration arguments for vcbuild.\n",
		"# written by buildfarm client \n",
		"use strict; \n",
		"use warnings;\n",
		"our $conf \n", "1;\n"
	);

	my $pgsql = $self->{pgsql};
	my $handle;
	open($handle, ">", "$pgsql/src/tools/msvc/config.pl")
	  || die "opening $pgsql/src/tools/msvc/config.pl: $!";
	print $handle @text;
	close($handle);

	push(@text, "# no configure step for MSCV - config file shown\n");

	writelog('configure', \@text);

	return;
}

sub configure
{
	my $self = shift;
	my $installdir = shift;
	print time_str(), "running configure ...\n" if $verbose;
	print $installdir;
	my $branch = $self->{pgbranch};
	if ($self->{bfconf}->{using_meson} && ($branch eq 'HEAD' || $branch ge 'REL_16_STABLE'))
	{
		$self->meson_setup($installdir);
		return;
	}

	if ($self->{bfconf}->{using_msvc})
	{
		$self->msvc_setup();
		return;
	}

	# autoconf/configure setup
	my $config_opts = $self->{bfconf}->{config_opts} || [];
	print "Config opts: ", join(", ", @$config_opts), "\n";
	my @quoted_opts;
	foreach my $c_opt (@$config_opts)
	{
		if ($c_opt =~ /['"]/)
		{
			push(@quoted_opts, $c_opt);
		}
		else
		{
			push(@quoted_opts, "'$c_opt'");
		}
	}

	my $confstr = join(" ",
		@quoted_opts, "--prefix=$installdir");

	# The use of accache kind of looks useless for this module since it will be a single build to be made, that too in only the first run case
	
	my $env = $self->{bfconf}->{config_env};
	$env = {%$env};    # shallow clone it
	if ($self->{bfconf}->{use_valgrind} && exists $self->{bfconf}->{valgrind_config_env_extra})
	{
		my $vgenv = $self->{bfconf}->{valgrind_config_env_extra};
		while (my ($key, $val) = each %$vgenv)
		{
			if (defined $env->{$key})
			{
				$env->{$key} .= " $val";
			}
			else
			{
				$env->{$key} = $val;
			}
		}
	}

	my $envstr = "";
	while (my ($key, $val) = each %$env)
	{
		$envstr .= "$key='$val' ";
	}

	my @confout = run_log("$envstr cd $installdir && ./pgsql/configure $confstr");

	my $status = $? >> 8;

	print "======== configure output ===========\n", @confout
	  if ($verbose > 1);

	if (-s "./pgsql/config.log")
	{
		my $log = PGBuild::Log->new("latest_tag_configure");
		$log->add_log("./pgsql/config.log");
		push(@confout, $log->log_string);
	}

	writelog('latest_tag_configure', \@confout);

	# if ($status)
	# {
	# 	send_result('Configure', $status, \@confout);
	# }

	return;
}

sub make
{
	my $self = shift;
	print time_str(), "running build ...\n" if $verbose;

	my $pgsql = $self->{pgsql};
	my (@makeout);
	if ($self->{bfconf}->{using_meson})
	{
		my $meson_jobs = $self->{bfconf}->{meson_jobs};
		my $jflag = defined($meson_jobs) ? " --jobs=$meson_jobs" : "";
		@makeout = run_log("meson compile -C $pgsql --verbose $jflag");
		move "$pgsql/meson-logs/meson-log.txt", "$pgsql/meson-logs/compile.log";
		if (-s "$pgsql/meson-logs/compile.log")
		{
			my $log = PGBuild::Log->new("compile");
			$log->add_log("$pgsql/meson-logs/compile.log");
			push(@makeout, $log->log_string);
		}
	}
	elsif ($self->{bfconf}->{using_msvc})
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = run_log("perl build.pl");
		chdir $branch_root;
	}
	else
	{
		my $make = $self->{bfconf}->{make} || 'make';
		my $make_jobs = $self->{bfconf}->{make_jobs} || 1;
		my $make_cmd = $make;
		$make_cmd = "$make -j $make_jobs"
		  if ($make_jobs > 1);
		@makeout = run_log("cd $pgsql && $make_cmd");
	}
	my $status = $? >> 8;
	writelog('build', \@makeout);
	print "======== make log ===========\n", @makeout if ($verbose > 1);
	$status ||= check_make_log_warnings('build', $verbose) if $check_warnings;
	# send_result('Build', $status, \@makeout) if $status;
	return;
}

sub make_install
{
	my $self = shift;
	my $installdir = shift;
	print time_str(), "running install ...\n" if $verbose;

	my $pgsql = $self->{pgsql};
	my @makeout;
	if ($self->{bfconf}->{using_meson})
	{
		@makeout = run_log("meson install -C $pgsql ");
		move "$pgsql/meson-logs/meson-log.txt", "$pgsql/meson-logs/install.log";
		my $log = PGBuild::Log->new("install");
		if (-s "$pgsql/meson-logs/install.log")
		{
			$log->add_file("$pgsql/meson-logs/install.log");
			push(@makeout, $log->log_string);
		}
	}
	elsif ($self->{bfconf}->{using_msvc})
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = run_log(qq{perl install.pl "$installdir"});
		chdir $branch_root;
	}
	else
	{
		my $make = $self->{bfconf}->{make} || 'make';
		@makeout = run_log("cd $pgsql && $make install");
	}
	my $status = $? >> 8;
	writelog('make-install', \@makeout);
	print "======== make install log ===========\n", @makeout if ($verbose > 1);
	# send_result('Install', $status, \@makeout) if $status;

	# On Windows and Cygwin avoid path problems associated with DLLs
	# by copying them to the bin dir where the system will pick them
	# up regardless.

	foreach my $dll (glob("$installdir/lib/*pq.dll"))
	{
		my $dest = "$installdir/bin/" . basename($dll);
		copy($dll, $dest);
		chmod 0755, $dest;
	}

	return;
}

sub _generate_abidw_xml
{
	my $self = shift;
	my $abidw_flags_str = join ' ', @{ $self->{abidw_flags_list} };
	my $commit_hash = shift;

	print time_str(), "Generating ABIDW XML for commit $commit_hash in ",
	  __PACKAGE__, "\n"
	  if $verbose;

	my $abi_compare_root = $self->{abi_compare_root};
	my $binaries_rel_path = $self->{binaries_rel_path};
	my $commit_xml_dir = "$abi_compare_root/xmls/$commit_hash";

	mkdir $commit_xml_dir unless -d $commit_xml_dir;

	my $install_dir = "$abi_compare_root/install";
	my $install_bin_dir = "$install_dir/bin";
	my $install_lib_dir = "$install_dir/lib";

	# Ensure $abi_compare_root/install/bin/ exists and has content
	unless (-d $install_bin_dir)
	{
		die
		  "Error: Directory $install_bin_dir does not exist. Cannot generate ABI XML for commit $commit_hash.";
	}
	unless (scalar glob("$install_bin_dir/*"))
	{
		die
		  "Error: Directory $install_bin_dir is empty. Cannot generate ABI XML for commit $commit_hash.";
	}

	my @targets_to_process = ();
	while (my ($target_name, $rel_path) = each %{$binaries_rel_path})
	{
		my $input_path = "$install_dir/$rel_path";
		my $output_file = "$commit_xml_dir/$target_name.abi";

		if (-e $input_path && -f $input_path)
		{
			my $cmd =
			  qq{abidw --out-file "$output_file" "$input_path" $abidw_flags_str};
			my $log_dir = "$abi_compare_root/logs/$commit_hash";
			my $log_file = "$log_dir/abidw-$target_name.log";
			my $exit_status =
			  _log_command_output($self, $cmd, $log_file,
				"abidw for $target_name", 1);

			if ($exit_status)
			{
				die
				  "abidw failed for $target_name (from $input_path) with status $exit_status. Commit: $commit_hash";
			}
			else
			{
				print time_str(),
				  "Successfully generated ABI XML for $target_name to $output_file\n"
				  if $verbose;
			}
		}
		else
		{
			print time_str(),
			  "Warning: Input file '$input_path' for $target_name not found. Skipping ABI generation for this target (commit $commit_hash).\n"
			  if $verbose;
		}
	}

	return;
}

sub cleanup
{
	my $self = shift;

	print time_str(), "cleaning up ", __PACKAGE__, "\n" if $verbose > 1;
	return;
}

1;
