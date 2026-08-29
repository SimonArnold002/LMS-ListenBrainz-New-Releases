#!/usr/bin/env perl
#
# t_buildwipe.pl — regression guard for the 0.9.174 review's finding 1: the genre
# half of the build wipe had NO release gate. `last_genre_fact` was written on every
# build and read by nothing, so a released upgrade that changed no genre code still
# cleared all four artist tiers, the release-group genres and the whole `lastfm_tags`
# table — the opposite of what the code comment and the 0.9.169 changelog both say.
#
#   perl tools/t_buildwipe.pl
#
# It reimplements nothing: `_buildChanged` is extracted VERBATIM from Plugin.pm
# (the tools/bench_walk.pl + t_review_fixes.pl trick) and driven against stub
# prefs/log/DB objects, so the assertions track the shipped code. No LMS needed.
#
# GENRE_FACT_VERSION is likewise read out of the real DB.pm, so a bump there does
# not quietly turn these assertions into a test of a stale number.
#
# LBF_PLUGIN points the suite at a MUTATED copy of Plugin.pm so every assertion can
# be anti-tested (break the gate, watch it go red). Without it the working tree is
# read, which is the normal run.
#
# Exit 0 = the gate holds. Exit 1 = it has regressed.
use strict;
use warnings;
use File::Spec;

my $ROOT = File::Spec->rel2abs(File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir));
my $PLUGIN = $ENV{LBF_PLUGIN}
    || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Plugin.pm');
my $DBPM   = $ENV{LBF_DB}
    || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'DB.pm');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
}
sub is {
    my ($got, $want, $what) = @_;
    $got  = defined $got  ? $got  : '(undef)';
    $want = defined $want ? $want : '(undef)';
    ok($got eq $want, "$what" . ($got eq $want ? '' : "  [got '$got', want '$want']"));
}

sub slurp {
    my ($f) = @_;
    open(my $fh, '<:encoding(UTF-8)', $f) or die "$f: $!";
    local $/; my $s = <$fh>; close $fh; return $s;
}

# Brace-matched verbatim extraction of a named sub (bench_walk.pl's `grab`).
sub grab {
    my ($src, $name) = @_;
    $src =~ /^sub \Q$name\E\b\s*\{/mg or die "no sub $name\n";
    my $start = $-[0];
    my $i     = pos($src);
    my $depth = 1;
    while ($i < length($src) && $depth) {
        my $c = substr($src, $i++, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
    }
    pos($src) = undef;
    return substr($src, $start, $i - $start) . "\n";
}

my $plugin_src = slurp($PLUGIN);
my $db_src     = slurp($DBPM);
my $sub_src    = grab($plugin_src, '_buildChanged');

# The REAL parser version, from the real DB.pm.
my ($GV) = $db_src =~ /^use constant GENRE_FACT_VERSION\s*=>\s*(\d+)/m;
die "no GENRE_FACT_VERSION in $DBPM\n" unless defined $GV;

# ---------------------------------------------------------------------------
# Stubs. The store counts what it was asked to wipe; nothing else is modelled.
# ---------------------------------------------------------------------------
our ($KV_CALLS, $GENRE_CALLS, $WIPE_DIES);
{
    package Plugins::ListenBrainzFreshReleases::DB;
    sub GENRE_FACT_VERSION { return $GV }
    # $WIPE_DIES models the real failure this guards: a locked DB during startup.
    # The call is COUNTED before it dies, because a half-done wipe is the state
    # that matters — the store is already partly cleared.
    sub wipeDerived { $KV_CALLS++; die "database is locked\n" if $WIPE_DIES; return 42 }
    sub wipeGenres  { $GENRE_CALLS++; return 7  }
}
# `require Plugins::ListenBrainzFreshReleases::DB` inside the sub must be a no-op.
$INC{'Plugins/ListenBrainzFreshReleases/DB.pm'} = 1;

our $VERSION_ON_DISK;
{
    package Slim::Utils::PluginManager;
    sub dataForPlugin { return { version => $VERSION_ON_DISK } }
}

{
    package StubPrefs;
    sub new  { my ($c, %h) = @_; return bless { %h }, $c }
    sub get  { return $_[0]->{ $_[1] } }
    sub set  { $_[0]->{ $_[1] } = $_[2]; return 1 }
}
{
    package StubLog;
    sub new   { return bless { warn => [], error => [] }, shift }
    sub warn  { push @{ $_[0]{warn} },  $_[1] }
    sub error { push @{ $_[0]{error} }, $_[1] }
}

# Each scenario gets its own package, because DEV_BUILD is a compile-time constant
# in the sub body — flipping it means re-compiling the body, which is exactly how
# the shipped code sees it.
my $pkg_n = 0;
our ($CUR_PREFS, $CUR_LOG);
sub run {
    my (%a) = @_;   # dev, installed (version on disk), last_build, last_genre_fact
    my $pkg = 'Scenario' . ++$pkg_n;
    my $prefs = StubPrefs->new(
        last_build      => $a{last_build},
        last_genre_fact => $a{last_genre_fact},
    );
    my $log = StubLog->new;
    ($CUR_PREFS, $CUR_LOG) = ($prefs, $log);
    $VERSION_ON_DISK = $a{installed};
    ($KV_CALLS, $GENRE_CALLS) = (0, 0);
    $WIPE_DIES = $a{wipe_dies} ? 1 : 0;

    # `$prefs` and `$log` are file-scope lexicals in Plugin.pm, and the sub closes
    # over them there — so give it lexicals of the same names here, seeded from the
    # globals above at eval time.
    my $code = "package $pkg;\n"
             . "use strict; use warnings;\n"
             . "use constant DEV_BUILD => $a{dev};\n"
             . "my \$prefs = \$main::CUR_PREFS;\n"
             . "my \$log   = \$main::CUR_LOG;\n"
             . $sub_src
             . "1;\n";
    eval $code or die "compile: $@";
    $pkg->can('_buildChanged')->();

    return {
        kv       => $KV_CALLS,
        genres   => $GENRE_CALLS,
        fact     => $prefs->get('last_genre_fact'),
        build    => $prefs->get('last_build'),
        warnings => join(' | ', @{ $log->{warn} }),
        errors   => join(' | ', @{ $log->{error} }),
    };
}

print "t_buildwipe.pl — the build wipe's genre gate\n";
print "  Plugin.pm: $PLUGIN\n  parser version: v$GV\n\n";

# ---------------------------------------------------------------------------
print "1. The pref is actually READ (the defect's signature)\n";
# The whole finding was that `last_genre_fact` was write-only. A `get` on it is the
# one thing that cannot be true of the broken code.
ok(scalar($plugin_src =~ /get\(\s*'last_genre_fact'\s*\)/),
   "Plugin.pm reads last_genre_fact, not just writes it");
ok(scalar($plugin_src =~ /^use constant DEV_BUILD\s*=>\s*[01]\s*;/m),
   'DEV_BUILD is declared as a 0/1 constant');
my ($dev_on_disk) = $plugin_src =~ /^use constant DEV_BUILD\s*=>\s*([01])/m;
print "  (DEV_BUILD is $dev_on_disk in the working tree — must be 0 at merge-to-main)\n";

# ---------------------------------------------------------------------------
print "\n2. A RELEASED build, parser unchanged: genres MUST survive\n";
{
    my $r = run(dev => 0, installed => '0.9.175',
                last_build => '0.9.174', last_genre_fact => $GV);
    is($r->{kv},     1, 'derived kv rows are still wiped (that rule is unconditional)');
    is($r->{genres}, 0, 'wipeGenres is NOT called');
    is($r->{fact},  $GV, 'last_genre_fact is left as it was');
    is($r->{build}, '0.9.175', 'last_build is advanced');
    ok(scalar($r->{warnings} =~ /genres KEPT/), 'the log says the genres were kept');
    is($r->{errors}, '', 'no error logged');
}

print "\n2b. A wipe that DIES must not record the build as handled\n";
# _buildChanged returns early when last_build already equals the running version,
# so the pref is what decides whether the wipe ever runs again. It used to be set
# AFTER the eval, unconditionally — so a wipe that died half way left a partly
# wiped store, recorded the build as done, and never retried for that version.
# That is the one path by which a dev build can silently not clear its caches,
# which is the standing rule the whole sub exists to enforce.
{
    my $r = run(dev => 1, installed => '0.9.185',
                last_build => '0.9.184', last_genre_fact => $GV, wipe_dies => 1);
    is($r->{kv},    1, 'the wipe was attempted');
    ok(scalar($r->{errors} =~ /Dev-build wipe failed/), '...and the failure is logged');
    is($r->{build}, '0.9.184',
       'last_build is NOT advanced, so the next start retries');
    # The store is genuinely half-done here — the die landed before the genre half —
    # which is exactly why "handled" would be a lie.
    is($r->{genres}, 0, 'the genre half never ran');
    is($r->{fact},  $GV, '...and its stamp was not advanced either');

    # The retry, modelled as the next server start: same prefs state, DB healthy.
    my $r2 = run(dev => 1, installed => '0.9.185',
                 last_build => $r->{build}, last_genre_fact => $r->{fact});
    is($r2->{kv},     1, 'the next start wipes again rather than skipping');
    is($r2->{genres}, 1, '...including the genre half it never reached');
    is($r2->{build}, '0.9.185', '...and only NOW records the build as handled');
    is($r2->{errors}, '', 'with no error the second time');
}

print "\n3. A RELEASED build, parser CHANGED: genres are cleared and stamped\n";
{
    my $stale = $GV - 1;
    my $r = run(dev => 0, installed => '0.9.175',
                last_build => '0.9.174', last_genre_fact => $stale);
    is($r->{genres}, 1, 'wipeGenres is called');
    is($r->{fact},  $GV, "last_genre_fact is advanced to v$GV");
    ok(scalar($r->{warnings} =~ /parser v\Q$stale\E -> v\Q$GV\E/),
       'the log names the parser versions it moved between');
}

print "\n4. A RELEASED build on a store that has NEVER been stamped\n";
{
    # The pref default is '' — an upgrade from any build before the stamp existed.
    # It must clear once and then never again.
    my $r = run(dev => 0, installed => '0.9.175',
                last_build => '0.9.174', last_genre_fact => '');
    is($r->{genres}, 1, 'wipeGenres is called on the first stamped build');
    is($r->{fact},  $GV, 'and the stamp is written');

    my $r2 = run(dev => 0, installed => '0.9.176',
                 last_build => '0.9.175', last_genre_fact => $r->{fact});
    is($r2->{genres}, 0, 'the NEXT release build leaves them alone');
}

print "\n5. A DEV build: every build still clears everything\n";
{
    my $r = run(dev => 1, installed => '0.9.175',
                last_build => '0.9.174', last_genre_fact => $GV);
    is($r->{kv},     1, 'kv wiped');
    is($r->{genres}, 1, 'wipeGenres is called even though the parser is unchanged');
    is($r->{fact},  $GV, 'the stamp is (re)written');
    ok(scalar($r->{warnings} =~ /dev build/), 'the log says why');
}

print "\n6. No build change at all: nothing is touched\n";
{
    for my $dev (0, 1) {
        my $r = run(dev => $dev, installed => '0.9.175',
                    last_build => '0.9.175', last_genre_fact => '');
        is($r->{kv},     0, "dev=$dev: kv untouched on a restart");
        is($r->{genres}, 0, "dev=$dev: genres untouched on a restart");
        is($r->{fact},  '', "dev=$dev: the stamp is not written on a restart");
    }
}

print "\n7. No version readable (dataForPlugin failed): a no-op, not a wipe\n";
{
    my $r = run(dev => 1, installed => '',
                last_build => '0.9.174', last_genre_fact => $GV);
    is($r->{kv},     0, 'nothing wiped');
    is($r->{genres}, 0, 'nothing wiped');
    is($r->{build}, '0.9.174', 'last_build is not advanced');
}

printf("\n%d passed, %d failed\n", $pass, $fail);
exit($fail ? 1 : 0);
