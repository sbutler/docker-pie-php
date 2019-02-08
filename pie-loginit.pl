#!/usr/bin/perl -w

use v5.10;
use strict;

use Config::Tiny;
use File::Basename;
use File::Spec::Functions;
use Fcntl;
use Getopt::Long;
use POSIX qw/mkfifo/;

my $opt_includedirs = $ENV{ 'PIE_PHPPOOLS_INCLUDE_DIRS' };
my $opt_logdir = $ENV{ 'PIE_PHPPOOLS_LOG_DIR' } || catdir( '/var', 'log', 'php-fpm' );
my $opt_logtype = $ENV{ 'PHP_LOGGING' } || '';
my $opt_logrotate = catfile( '/etc', 'logrotate.d', 'php-fpm' );

if (not $opt_includedirs && $ENV{ 'PIE_PHP_VERSION' }) {
    $opt_includedirs = join( ':',
        catdir( '/etc', 'php', $ENV{ 'PIE_PHP_VERSION' }, 'fpm', 'pool.d' ),
        catdir( '/etc', 'opt', 'pie', 'php', $ENV{ 'PIE_PHP_VERSION' }, 'fpm', 'pool.d' )
    );
}

unless (GetOptions(
    'include-dirs|i=s'      => \$opt_includedirs,
    'log-dir|l=s'           => \$opt_logdir,
    'log-type|t=s'          => \$opt_logtype,
    'logrotate|r=s'         => \$opt_logrotate,
)) {
    say STDERR "usage: [-i INCLUDE_DIRS] [-l LOG_DIR] [-t pipe|file|link] [-r LOGROTATE_FILE]";
    say STDERR "Parses the PHP-FPM pool configurations and setup logging destinations a logrotate.conf file (if files).";
    exit 1;
}

my @opt_includedirs = grep { $_ } split /:/, $opt_includedirs;

unless (@opt_includedirs) {
    say STDERR "[ERROR] INCLUDE_DIRS is required";
    exit 1;
}
unless ($opt_logdir) {
    say STDERR "[ERROR] LOG_DIR is required";
    exit 1;
}
unless ($opt_logrotate) {
    say STDERR "[ERROR] LOGROTATE_FILE is required";
    exit 1;
}

sub expand_env {
    my $s = shift || '';

    $s =~ s/\$\{([a-zA-Z_][a-zA-Z0-9_]*)\}/(exists $ENV{$1}) ? $ENV{$1} : ''/sge;
    return $s;
}

my $def_mod = 0640;
my $def_uid = 0;
my $def_gid;
{
    my @ent = getgrnam( 'adm' );
    if (@ent) {
        $def_gid = $ent[ 2 ];
    } else {
        $def_gid = 0;
    }
}
say "[INFO] default uid = $def_uid; gid = $def_gid; mode = $def_mod";

my %logfiles = (
    # Add this for all pools to use if wanted
    catfile( $opt_logdir, 'access.log' ) => {
        owner   => $def_uid,
        group   => $def_gid,
        mode    => $def_mod,
    }
);
INCLUDE_DIR: foreach my $dir (@opt_includedirs) {
    my $pattern = sprintf( '"%s"', catfile( $dir, "*.conf" ) );
    CONF_FILE: foreach my $file (glob $pattern) {
        say "[INFO] Reading configuration file $file";
        my $config = Config::Tiny->read( $file ) || next;

        CONF_POOL: foreach my $section (keys %$config) {
            next if $section eq '_';

            my $pool = $config->{ $section };
            next unless $pool->{ 'user' };
            say "[INFO] Processing pool $section";

            my ($pool_user, $pool_group) = (
                expand_env( $pool->{ 'user' } ),
                expand_env( $pool->{ 'group' } ),
            );
            my ($pool_uid, $pool_gid) = ($pool_user, $pool_group);

            # Lookup the pool UID information
            my @pool_uid_ent;
            if ($pool_uid !~ /^\d+$/) {
                @pool_uid_ent = getpwnam( $pool_uid );
                $pool_uid = $pool_uid_ent[ 2 ] if @pool_uid_ent;
            } else {
                @pool_uid_ent = getpwuid( $pool_uid );
            }
            unless (@pool_uid_ent) {
                say "[WARN] Unable to get entry for pool user $pool_user";
                next CONF_POOL;
            }

            # Lookup the pool GID information, or use the default if
            # one isn't specified in the ini.
            if (not defined $pool_gid) {
                $pool_gid = $pool_uid_ent[ 3 ];
            } elsif ($pool_gid !~ /^\d+$/) {
                my @pool_gid_ent = getgrnam( $pool_gid );
                unless (@pool_gid_ent) {
                    say "[WARN] Unable to get entry for pool group $pool_group";
                    next CONF_POOL;
                }

                $pool_gid = $pool_gid_ent[ 2 ];
            }
            say "[INFO] pool uid = $pool_uid; gid = $pool_gid";

            my $add_logfile = sub {
                my $file = shift;

                unless ($file) {
                    say "[INFO] no file specified for $section entry";
                    return;
                }

                if (dirname( $file ) ne $opt_logdir) {
                    say "[WARN] $file is not in the log directory (skipping)";
                    return;
                }

                if (exists $logfiles{ $file }) {
                    say "[WARN] $file has already been specified (skipping)";
                    return;
                }

                say "[INFO] adding $file for pool";
                $logfiles{ $file } = {
                    owner   => $pool_uid,
                    group   => $pool_gid,
                    mode    => $def_mod,
                };
            };

            for my $k ('slowlog', 'access.log') {
                &$add_logfile( expand_env( $pool->{ $k } ) );
            }
            foreach my $k (keys %$pool) {
                if ($k =~ /^php(_admin)?_value\[error_log\]$/) {
                    &$add_logfile( expand_env( $pool->{ $k } ) );
                    last;
                }
            }
        }
    }
}

if ($opt_logtype eq 'pipe') {
    PIPE_LOGFILE: while (my ($file, $perms) = each %logfiles) {
        if (-e $file && ! -p _) {
            say "[WARN] Removing existing file $file";
            unlink $file;
        }

        if (! -e $file) {
            unless (mkfifo( $file, $perms->{ 'mode' } )) {
                say STDERR "[ERROR] Cannot mkfifo $file: $!";
                next PIPE_LOGFILE;
            }
        } elsif (!chmod $perms->{ 'mode' }, $file) {
            say "[WARN] Unable to change mode for $file: $!";
        }

        unless (chown $perms->{ 'owner' }, $perms->{ 'group' }, $file) {
            say "[WARN] Unable to change ownership for $file: $!";
        }
    }

    unlink $opt_logrotate;
} elsif ($opt_logtype eq 'file') {
    my @postrotate;
    FILE_LOGFILE: for my $file (sort keys %logfiles) {
        my $perms = $logfiles{ $file };
        if (-e $file && ! -f _) {
            say "[WARN] Removing existing file $file";
            unlink $file;
        }

        if (! -e $file) {
            if (sysopen my $fh, $file, O_WRONLY|O_CREAT, $perms->{ 'mode' }) {
                close $fh;
            } else {
                say STDERR "[ERROR] Cannot create $file: $!";
                next FILE_LOGFILE;
            }
        } elsif (!chmod $perms->{ 'mode' }, $file) {
            say "[WARN] Unable to change mode for $file: $!";
        }

        unless (chown $perms->{ 'owner' }, $perms->{ 'group' }, $file) {
            say "[WARN] Unable to change ownership for $file: $!";
        }

        push @postrotate, sprintf( "chmod 0\%.3o '\%s'", $perms->{ 'mode' }, $file );
        push @postrotate, sprintf( "chown %d:%d '\%s'", $perms->{ 'owner' }, $perms->{ 'group' }, $file );
    }

    if (open my $fh, '>', $opt_logrotate) {
        my $files = join( ' ', map { sprintf '"%s"', $_ } sort keys %logfiles);
        my $postrotate = join( "; \\\n        ", @postrotate );

        say $fh <<"EOF";
${files} {
    missingok
    compress
    delaycompress
    notifempty
    create 640 root adm
    sharedscripts
    postrotate
        ${postrotate}; \\
        \\
        kill -USR1 1;
    endscript
    prerotate
        for f in "\$1"; do \\
            if [ -L "\$f" -o ! -f "\$f" ]; then \\
                exit 1; \\
            fi; \\
        done;
    endscript
}
EOF
        close $fh;
    } else {
        say STDERR "[ERROR] Unable to write to $opt_logrotate: $!";
    }
} else {
    LINK_LOGFILE: while (my ($file, $perms) = each %logfiles) {
        if (-e $file && ! -l $file) {
            say "[WARN] Removing existing file $file";
            unlink $file;
        }

        if (! -e $file) {
            unless (symlink '/proc/self/fd/2', $file) {
                say STDERR "[ERROR] Cannot symlink $file: $!";
                next LINK_LOGFILE;
            }
        }
    }

    unlink $opt_logrotate;
}
