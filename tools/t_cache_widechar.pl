#!/usr/bin/env perl
# Reproduce the "Wide character in subroutine entry" cache failure exactly as
# Slim::Utils::DbCache::set triggers it, then prove the _setText/_getText fix.
#
# DbCache::set does, in essence:
#     $data = freeze($data) if ref $data;      # <-- plain scalars skip this
#     $sth->bind_param(2, $data, DBI::SQL_BLOB);
use strict;
use warnings;
use DBI;
use Storable qw(freeze thaw);

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, PrintError => 0 });
$dbh->do('CREATE TABLE cache (k INTEGER PRIMARY KEY, v BLOB)');

# Faithful stand-in for DbCache::set / ->get
my $n = 0;
sub db_set {
    my ($key, $data) = @_;
    $data = freeze($data) if ref $data;   # refs only — exactly what DbCache::set does
    my $sth = $dbh->prepare('INSERT OR REPLACE INTO cache (k,v) VALUES (?,?)');
    $sth->bind_param(1, ++$n);
    $sth->bind_param(2, $data, DBI::SQL_BLOB);
    $sth->execute;
    return $n;
}
sub db_get {
    my ($k) = @_;
    my ($v) = $dbh->selectrow_array('SELECT v FROM cache WHERE k = ?', undef, $k);
    return $v;
}

# The plugin's fix, verbatim in shape.
sub _setText { my ($text) = @_; return db_set(undef, { t => $text }) }
sub _getText { my ($k) = @_; my $c = db_get($k); $c = eval { thaw($c) } || $c; return ref $c eq 'HASH' ? $c->{t} : $c }

my %CASES = (
    'ASCII sort-name         ' => 'White, Jack',
    'Latin-1 (u-umlaut)      ' => "Bj\x{f6}rk",
    'Japanese (CJK)          ' => "\x{30ca}\x{30ca}\x{30b8}\x{30e5}\x{30a6}\x{30cf}\x{30c1}",
    'Cyrillic                ' => "\x{41c}\x{443}\x{43c}\x{438}\x{439} \x{422}\x{440}\x{43e}\x{43b}\x{44c}",
    'bio with a curly quote  ' => "It\x{2019}s a band \x{2014} formed in 1998.",
);

print "BEFORE THE FIX — bare scalar, as DbCache stores it:\n";
my $failed = 0;
for my $name (sort keys %CASES) {
    my $ok = eval { db_set(undef, $CASES{$name}); 1 };
    printf "  %s %s\n", $name, $ok ? 'stored' : "DIED: " . (split / at /, "$@")[0];
    $failed++ unless $ok;
}

print "\nAFTER THE FIX — _setText wraps it so Storable handles the encoding:\n";
my $bad = 0;
for my $name (sort keys %CASES) {
    my $k = eval { _setText($CASES{$name}) };
    unless ($k) { printf "  %s DIED: %s\n", $name, (split / at /, "$@")[0]; $bad++; next }
    my $back = _getText($k);
    my $same = defined $back && $back eq $CASES{$name};
    $bad++ unless $same;
    printf "  %s stored + read back %s\n", $name, $same ? 'IDENTICAL' : "CORRUPTED ($back)";
}

# A pre-0.9.142 entry (bare string, written before the fix) must still read back.
my $legacy = db_set(undef, 'White, Jack');
printf "\nLegacy bare-string entry reads back: %s\n",
    (_getText($legacy) // '') eq 'White, Jack' ? 'OK (no cache prefix bump needed)' : 'BROKEN';

printf "\n%d of %d cases died before the fix; %d problems after.\n", $failed, scalar keys %CASES, $bad;
exit($bad ? 1 : 0);
