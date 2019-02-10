#!/usr/bin/perl -w

use v5.10;
use strict;

use Config::Tiny;
use File::Basename;
use File::Spec::Functions;
use Getopt::Long;

my $opt_includedirs = $ENV{ 'PIE_PHPPOOLS_INCLUDE_DIRS' };
my $opt_statusurls_file = $ENV{ 'PIE_PHPPOOLS_STATUSURLS_FILE' } || catfile( '/run', 'php-fpm.d', 'status-urls.txt' );
my $opt_pingurls_file = $ENV{ 'PIE_PHPPOOLS_PINGURLS_FILE' } || catfile( '/run', 'php-fpm.d', 'ping-urls.txt' );
my $opt_user;
my $opt_group;

if (not $opt_includedirs && $ENV{ 'PIE_PHP_VERSION' }) {
    $opt_includedirs = join( ':',
        catdir( '/etc', 'php', $ENV{ 'PIE_PHP_VERSION' }, 'fpm', 'pool.d' ),
        catdir( '/etc', 'opt', 'pie', 'php', $ENV{ 'PIE_PHP_VERSION' }, 'fpm', 'pool.d' )
    );
}

unless (GetOptions(
    'include-dirs|i=s'      => \$opt_includedirs,
    'status-urls-file|s=s'  => \$opt_statusurls_file,
    'ping-urls-file|p=s'    => \$opt_pingurls_file,
    'user|u=s'              => \$opt_user,
    'group|g=s'             => \$opt_group,
)) {
    say STDERR "usage: [-i INCLUDE_DIRS] [-s STATUS_URLS_FILE] [-p PING_URLS_FILE]";
    say STDERR "Parses the PHP-FPM pool configurations and outputs an lighttpd configuration and list of pool status and ping URLs.";
    exit 1;
}

my @opt_includedirs = grep { $_ } split /:/, $opt_includedirs;

unless (@opt_includedirs) {
    say STDERR "INCLUDE_DIRS is required";
    exit 1;
}
unless ($opt_statusurls_file) {
    say STDERR "STATUS_URLS_FILE is required";
    exit 1;
}
unless ($opt_pingurls_file) {
    say STDERR "PING_URLS_FILE is required";
    exit 1;
}

my %pools;
INCLUDE_DIR: foreach my $dir (@opt_includedirs) {
    my $pattern = sprintf( '"%s"', catfile( $dir, "*.conf" ) );
    CONF_FILE: foreach my $file (glob $pattern) {
        my $config = Config::Tiny->read( $file ) || next;

        CONF_POOL: foreach my $section (keys %$config) {
            next if $section eq '_';
            next unless $config->{ $section }->{ 'listen' };

            $pools{ $section } = {
                'listen'    => $config->{ $section }->{ 'listen' },
                'status'    => $config->{ $section }->{ 'pm.status_path' },
                'ping'      => $config->{ $section }->{ 'ping.path' },
            };
        }
    }
}

sub open_urls(*$) {
    my $file = $_[ 1 ];

    my $dir = dirname( $file );
    unless (((! -e $file) && -w $dir) || (-e $file && -w _)) {
        say STDERR "cannot open $file or write to directory $dir";
        return;
    }

    open $_[ 0 ], '>', $file or die "cannot open $file: $!";
    if ($opt_user) {
        my ($uid, $gid);

        if ($opt_user =~ /^\d+$/) {
            $uid = $opt_user;
        } else {
            my @res = getpwnam($opt_user) or die "cannot find user $opt_user: $!";
            $uid = $res[ 2 ];
            $gid = $res[ 3 ];
        }

        if ($opt_group) {
            if ($opt_group =~ /^\d+$/) {
                $gid = $opt_group;
            } else {
                my @res = getgrnam($opt_group) or die "cannot find group $opt_group: $!";
                $gid = $res[ 2 ];
            }
        }

        chown $uid, $gid, $file;
    }
}

my ($statusurls_fh, $pingurls_fh);
open_urls $statusurls_fh, $opt_statusurls_file;
open_urls $pingurls_fh, $opt_pingurls_file;


say "fastcgi.server += (";

POOL: foreach my $name (sort keys %pools) {
    my $values = $pools{ $name };

    my $connect;
    if ($values->{ 'listen' } =~ /^(([0-9.]+)|(\[[0-9a-f:]+\]):)?(?<port>\d+)$/i) {
        my $port = $+{ 'port' };
        $connect = <<HERE;
        "host"          => "127.0.0.1",
        "port"          => $port,
HERE
    } else {
        my $socket = $values->{ 'listen' };
        $connect = <<HERE;
        "socket"        => "$socket",
HERE
    }

    PATH: foreach my $key (qw/ping status/) {
        my $url = $values->{ $key };
        next PATH unless $url;

        say <<HERE;
    "$url" => ((
$connect
        "check-local"   => "disable",
    )),
HERE
    }

    printf $statusurls_fh "%s %s\n", $name, $values->{ 'status' } if $statusurls_fh && $values->{ 'status' };
    printf $pingurls_fh "%s %s\n", $name, $values->{ 'ping' } if $pingurls_fh && $values->{ 'ping' };
}

say ")";
close $statusurls_fh if $statusurls_fh;
close $pingurls_fh if $pingurls_fh;
