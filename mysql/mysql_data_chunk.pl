#!/usr/bin/env perl
#
# MySQL Data Chunk Script
#
# The most popular DBA script for MySQL who; Percona ToolKit, MySQL Utilities,
# MyTop, and MySQLTuner is written in Perl, because I chose that.
#
# This is is mature, proven in the real world, and well tested, but all database
# tools can pose a risk to the system and the database server. Before using this
# tool, please:
#
#  - Read the tool’s documentation
#  - Review the tool’s known “BUGS”
#  - Test the tool on a non-production server
#  - Backup your production server and verify the backups
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# This project would not be possible without help from:
# - Nicola Strappazzon Carotenuto
#
# TODO:
# =====
# - Reverse chunk process.
# - Replication lag detection.
# - Add pid control to prevent the same execution command.
#

use strict;
use warnings FATAL => 'all';
use Getopt::Long;
use POSIX;

eval {
  require DBI;
};

if ( $@ ) {
  die "Perl DBI module id not installed. \n"
    . "  Debian/Ubuntu apt-get install libdbi-perl\n"
    . "  RHEL/CentOS   yum install perl-DBI\n";
}

# --- Define command line ------------------------------------------------------
our $VERSION = '0.1.0';
my $OPTIONS = <<"_OPTIONS";

MySQL Data Chunk Script

$0 Ver $VERSION

Usage: $0 --schema=sakila --table=film --key=film_id --template=template.txt

  -?, --help           Display this help-screen and exit
  -u, --user=#         User name for database login
  -p, --password=#     Password for database login
  -h, --host=#         Hostname to connecting to the server
  -P, --port=#         Port nomber to connecting to the server
  -d, --schema=#       Schema name
  -T, --table=#        Table name to chunk
  -t, --template=#     SQL template file
  -k, --key=#          Primary Key name
  -S, --sleep=#        Time sleep between chunk
  -c, --chunk=#        Define chunk size
  -s, --start=#        Start chunk from ID
  -e, --end=#          End chunk to ID

SQL Template example:

  UPDATE [TABLE] SET last_update = NOW() WHERE film_id BETWEEN [START] AND [END];

SQL Template Variables:

  - [TABLE]   Table name when apply UPDATE or DELETE or INSERT
  - [START]   Primary Key (ID) to start on table.
  - [END]     Primary Key (ID) to end on table.

_OPTIONS

my %opt = (
  "host"  => "127.0.0.1",
  "user"  => "root",
  "port"  => 3306,
  "sleep" => 0,
  "chunk" => 100,
  "start" => 0,
  "end"   => 0,
  "key"   => "id",
);

# Disambiguate -p and -P
Getopt::Long::Configure(qw(no_ignore_case));

GetOptions(\%opt,
  "help",
  "host|h=s",
  "user|u=s",
  "password|p=s",
  "port|P=i",
  "table|T=s",
  "template|t=s",
  "key|k=s",
  "schema|d=s",
  "sleep|S=i",
  "chunk|c=i",
  "start|s=i",
  "end|e=i",
) or usage("Invalid option");

usage() if ($opt{help});

# --- Validate required parameter ----------------------------------------------
unless (
  defined $opt{schema}   &&
  defined $opt{table}    &&
  defined $opt{template}
) {
  usage();
}

# --- Define basic variables ---------------------------------------------------
my $chunk_end        = 0;
my $chunk_percentage = 0;
my $chunk_start      = 0;
my $chunk_total      = 0;
my $dsn              = '';
my $row_count        = 0;
my $row_delta        = 0;
my $row_total        = 0;
my $sql_count        = '';
my $sql_template     = '';
my $sth;
my $table            = $opt{table};
my $template         = '';

# --- Prepare SQL from template ------------------------------------------------
#
# Load template from file
open my $file, '<', $opt{template} or die "Could not open template: $opt{template}\n";

$template = do { local $/; <$file> };

# Clear string
$sql_template = join(' ', $template);
$sql_template =~ s/\n//g;
$sql_template =~ s/ +/ /g;

# Validate template
if (index($sql_template, '[TABLE]') == -1) {
  die "SQL template not contain [TABLE] variable.\n";
}

if (index($sql_template, '[START]') == -1) {
  die "SQL template not contain [START] variable.\n";
}

if (index($sql_template, '[END]') == -1) {
  die "SQL template not contain [END] variable.\n";
}

# --- Connect to the database --------------------------------------------------
my $dbh;
$dsn  = ";host=$opt{host}";
$dsn .= ";port=$opt{port}";
$dsn .= ";database=$opt{schema}";

eval {
  $dbh = DBI->connect("dbi:mysql:$dsn;", $opt{user}, $opt{password},
  {
    RaiseError => 0,
    PrintError => 0,
    AutoCommit => 1,
  }) or die $DBI::errstr . "\n";
};

if ( $@ =~ m/locate DBD\/mysql/i ) {
  die "Perl DBI::mysql module id not installed. \n"
    . "  Debian/Ubuntu apt-get install libdbd-mysql-perl\n"
    . "  RHEL/CentOS   yum install perl-DBD-MySQL\n";
}

# --- Calculate loop -----------------------------------------------------------
$sql_count = "SELECT MAX($opt{key}) FROM $opt{schema}.$opt{table}";

$sth = $dbh->prepare($sql_count);
$sth->execute or die "SQL Error: $DBI::errstr\n";
$row_count = $sth->fetchrow_array();
$sth->finish;

$row_delta   = $opt{chunk} * 2;
$row_total   = $row_count + $row_delta;
$chunk_total = $row_total / $opt{chunk};

print "Calculator summary:\n";
print " - Max rows in table: $row_count \n";
print " - Delta: $row_delta\n";
print " - Total: $row_total\n";
print " - Chunk size: $opt{chunk}\n";
print " - Number of chunks: $chunk_total\n";
print "\n";

# --- Chunk loop ---------------------------------------------------------------
for (my $row_id=1; $row_id <= $chunk_total; $row_id++) {
  # Calculate chunk
  $chunk_start      = (($row_id * $opt{chunk}) - $opt{chunk}) + 1;
  $chunk_end        = ($row_id * $opt{chunk});
  $chunk_percentage = ((100 * $row_id) / $chunk_total);
  $chunk_percentage = sprintf("%.0f", $chunk_percentage);

  # Resume process with start and end table id
  if ($opt{start} > 0 && $chunk_end <= $opt{start}) {
    &log($row_id, $chunk_percentage, $chunk_start, $chunk_end, 'Ignored!');
    next;
  }

  if ($opt{end} > 0 && $chunk_start > $opt{end}) {
    &log($row_id, $chunk_percentage, $chunk_start, $chunk_end, 'Ignored!');
    next;
  }

  # Add variables into template
  $sql_template =~ s/\[TABLE\]/$table/g;
  $sql_template =~ s/\[START\]/$chunk_start/g;
  $sql_template =~ s/\[END\]/$chunk_end/g;

  # Execute query
  &log($row_id, $chunk_percentage, $chunk_start, $chunk_end, 'Applying...');

  $sth = $dbh->prepare($sql_template);
  $sth->execute or die "SQL Error: $DBI::errstr\n";

  # Wait N seconds
  sleep($opt{sleep});
}

# --- Disconnect from the MySQL database ---------------------------------------
$dbh->disconnect;

# --- Start subroutine ---------------------------------------------------------
sub usage {
  die @_, $OPTIONS;
}

sub log {
  my ($chunk, $percentage, $start, $end, $message) = @_;
  my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
  my $timestamp;

  $chunk      = sprintf("%*d", length($chunk_total), $chunk);
  $end        = sprintf("%*d", length($row_total), $end);
  $start      = sprintf("%*d", length($row_total), $start);
  $percentage = sprintf("%3d", $percentage);
  $timestamp  = strftime "%Y/%m/%d %H:%M:%S", localtime;

  print "$timestamp $chunk/$chunk_total $percentage% ($start, $end) $message\n";
}
