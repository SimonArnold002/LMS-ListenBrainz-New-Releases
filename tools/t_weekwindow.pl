#!/usr/bin/env perl
#
# t_weekwindow.pl — the whole-week release window (0.9.185).
#
#   perl tools/t_weekwindow.pl
#
# WHAT THIS PROTECTS, AND WHY EACH ASSERTION EXISTS.
#
# The window used to be a rolling DAY count measured from today, and the bug that
# killed it is not a crash — it is a release quietly disappearing. The UI renders
# in whole Monday-to-Sunday weeks, but the window's edges landed on arbitrary
# days, so with "include earlier weeks" off the current week's row held only today
# onwards and FRIDAY'S RELEASES were gone by Saturday. Section 3 is that exact
# scenario, run for every day of a real week: it is the assertion the feature
# exists for, and it is the one that goes red if anyone reintroduces a
# today-relative edge.
#
# The rest are the failure shapes around it:
#
#   - THE BUDGET MUST HOLD FROM BOTH DIRECTIONS. The prefs are clamped on save AND
#     at read time, because prefs.yaml is hand-editable and the values are
#     multiplied out into a date range. A suite that only tested the Settings
#     clamp would pass against a hand-edited 52.
#
#   - `future` MUST COME BACK TRUE WITH THE LATER-WEEKS BOX OFF. That reads like a
#     bug and is the mechanism behind whole weeks: the current week runs to Sunday,
#     so days ahead of today are always being asked for. Section 4 pins it so a
#     future tidy-up cannot "fix" it back into the half-week bug.
#
#   - THE GATE DEFAULTS MUST AGREE WITH Plugin.pm's $prefs->init. The old read
#     sites DISAGREED — foryou_future fell back to `// 0` in four places and `// 1`
#     in warmFeeds — so a warm and a browse asked ListenBrainz two different
#     questions and stored two different windows. Section 5 derives the expected
#     defaults FROM Plugin.pm rather than restating them, because a hand-copied
#     default is exactly how that drift happened.
#
#   - THE MEMO KEY THE FETCHER BUILDS AND THE ONE clearFeedCache DROPS MUST BE THE
#     SAME KEY. When they diverge, Refresh drops a key nobody holds and goes on
#     serving the copy it was meant to replace — the 0.9.141 bug. Section 6 is
#     textual because the two are built in different subs from different scopes.
#
#   - THE CHECKBOX-COERCION SENTINEL MUST NAME A FIELD THE FORM ACTUALLY POSTS.
#     `pref_days` was that sentinel, and `days` is retired. Removing the field
#     without moving the sentinel breaks EVERY checkbox on the settings page at
#     once, silently: unchecked boxes store undef and read back ON through the
#     `// 1` guards, so all_past / foryou_past become impossible to turn off.
#     Section 7 ties the sentinel in Settings.pm to a field in settings.html.
#
# ANTI-TEST (do this after changing anything here — a green baseline against a
# window helper that ignores its arguments is worth nothing):
#
#   cp ListenBrainzFreshReleases/API.pm /tmp/API.pm
#   # in /tmp/API.pm make _feedWindow return ($today, $today)
#   LBF_API=/tmp/API.pm perl tools/t_weekwindow.pl     # must go RED (sections 1-4)
#
# Exit 0 = all good. Exit 1 = at least one regressed.

use strict;
use warnings;
use FindBin;
use File::Spec;

my $ROOT     = File::Spec->catdir($FindBin::Bin, File::Spec->updir);
my $PLUGDIR  = File::Spec->catdir($ROOT, 'ListenBrainzFreshReleases');
# Overridable so an anti-test run can point the suite at a MUTATED copy. Without
# it the run silently reads the working tree and "passes" (t_review_fixes.pl).
my $API      = $ENV{LBF_API}    || File::Spec->catfile($PLUGDIR, 'API.pm');
my $DB       = $ENV{LBF_DB}     || File::Spec->catfile($PLUGDIR, 'DB.pm');
my $BROWSE   = $ENV{LBF_BROWSE} || File::Spec->catfile($PLUGDIR, 'Browse.pm');
my $SETTINGS = File::Spec->catfile($PLUGDIR, 'Settings.pm');
my $PLUGIN   = File::Spec->catfile($PLUGDIR, 'Plugin.pm');
my $TMPL     = File::Spec->catfile($PLUGDIR, qw(HTML EN plugins ListenBrainzFreshReleases settings.html));

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
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

my $api_src      = slurp($API);
my $db_src       = slurp($DB);
my $browse_src   = slurp($BROWSE);
my $settings_src = slurp($SETTINGS);
my $plugin_src   = slurp($PLUGIN);
my $tmpl_src     = slurp($TMPL);

# ---------------------------------------------------------------------------
# Build a live copy of the REAL helpers.
#
# The date arithmetic is lifted from DB.pm rather than reimplemented here for the
# usual reason: a suite that asserts a Monday it worked out itself asserts nothing
# about the Monday the plugin computes. _weekStart is the single shared week-start
# implementation, so the test and the code have to be reading the same one.
# ---------------------------------------------------------------------------
{
    no strict 'refs';
    for my $s (qw(_weekStart _toDays _fromDays)) {
        eval "package Plugins::ListenBrainzFreshReleases::DB; " . grab($db_src, $s) . "1;"
            or die "DB::$s: $@";
    }
    $INC{'Plugins/ListenBrainzFreshReleases/DB.pm'} = __FILE__;
}

# Stub prefs: a plain hash, so a MISSING pref really is undef and every `//`
# default in the lifted code is exercised rather than papered over.
my %PREF;
{
    package StubPrefs;
    sub get { $PREF{ $_[1] } }
    sub set { $PREF{ $_[1] } = $_[2] }
}

# The constants, the gate table and the helpers, verbatim from API.pm.
{
    my $code = "package T; use strict; use warnings;\n"
             . "my \$prefs = bless {}, 'StubPrefs';\n";
    for my $c (qw(WEEKS_MAX_SIDE WEEKS_PAST_DEFAULT WEEKS_FUTURE_DEFAULT)) {
        $api_src =~ /^(use constant \Q$c\E\s*=>.*?;)/m or die "no constant $c\n";
        $code .= "$1\n";
    }
    $api_src =~ /^(my %WEEK_GATES = \(.*?\n\);)/ms or die "no %WEEK_GATES\n";
    $code .= "$1\n";
    $code .= grab($api_src, $_) for qw(_clampWeeks _feedWindow _feedRequestDays
                                       _shiftDay _spanDays sectionWeeks sectionWindow);
    $code .= "1;";
    eval $code or die "lifting API helpers: $@";
}

# _today is the ONE thing that is stubbed rather than lifted: every assertion here
# is about where a boundary lands relative to a given day, so the day has to be
# chosen. Set through $TODAY.
our $TODAY = '2026-08-22';
{ no strict 'refs'; *{'T::_today'} = sub { $TODAY }; }

sub win  { local $TODAY = shift; T::_feedWindow(@_) }
sub secw { local $TODAY = shift; T::sectionWeeks(@_) }
# _feedRequestDays calls _today() ITSELF, so the stubbed day has to stay in scope
# across the window call AND the derivation. Splitting them (win(...) then
# _feedRequestDays(...)) restores $TODAY in between and silently measures the
# window of one day against the "today" of another.
sub reqd { my $d = shift; local $TODAY = $d; T::_feedRequestDays(T::_feedWindow(@_)) }

# 2026-08-17 is a Monday; 21st Friday, 22nd Saturday, 23rd Sunday.
my @WEEK = qw(2026-08-17 2026-08-18 2026-08-19 2026-08-20 2026-08-21 2026-08-22 2026-08-23);
my @DOW  = qw(Monday Tuesday Wednesday Thursday Friday Saturday Sunday);

print "\nSECTION 1 — the four-week budget holds, from prefs and from garbage\n";
print "-" x 74, "\n";
{
    my @c;
    @c = T::_clampWeeks(undef, undef);
    ok("@c" eq '1 2', 'missing prefs fall back to the shipped 1 back / 2 ahead');
    @c = T::_clampWeeks(0, 0);
    ok("@c" eq '0 0', 'zero on both sides is legal — the current week alone');
    @c = T::_clampWeeks(3, 0);
    ok("@c" eq '3 0', '3 + 0 is exactly the budget and is left alone');
    @c = T::_clampWeeks(3, 3);
    ok("@c" eq '3 0', '3/3 clamps to the budget, past honoured first');
    @c = T::_clampWeeks(2, 2);
    ok("@c" eq '2 1', '2/2 (five weeks) clamps to four, trimming the future side');
    @c = T::_clampWeeks(52, 52);
    ok("@c" eq '3 0', 'a hand-edited 52/52 cannot produce a year-wide window');
    @c = T::_clampWeeks('banana', '-4');
    ok("@c" eq '1 2', 'garbage and a negative both fall back to the defaults');
    # The budget is the invariant, not any one clamp branch: assert it over the
    # whole input space rather than at the points that happen to be listed above.
    my $overrun = 0;
    for my $p (0 .. 8) {
        for my $f (0 .. 8) {
            my ($cp, $cf) = T::_clampWeeks($p, $f);
            $overrun++ if $cp + $cf > T::WEEKS_MAX_SIDE()
                       || $cp < 0 || $cf < 0
                       || $cp > T::WEEKS_MAX_SIDE() || $cf > T::WEEKS_MAX_SIDE();
        }
    }
    ok(!$overrun, 'no (past, future) pair in 0..8 x 0..8 escapes the budget');
}

print "\nSECTION 2 — the window is WHOLE weeks, Monday to Sunday, on every day\n";
print "-" x 74, "\n";
{
    my ($mondayOK, $sundayOK, $spanOK) = (1, 1, 1);
    for my $i (0 .. $#WEEK) {
        my ($from, $to) = win($WEEK[$i], 1, 2);
        $mondayOK = 0 unless $from eq '2026-08-10';   # one whole week before the 17th
        $sundayOK = 0 unless $to   eq '2026-09-06';   # Sunday ending the 2nd week ahead
        $spanOK   = 0 unless T::_spanDays($from, $to) == 27;
    }
    ok($mondayOK, 'the FROM edge is the same Monday whichever day of the week it is');
    ok($sundayOK, 'the TO edge is the same Sunday whichever day of the week it is');
    ok($spanOK,   'the span is a whole number of weeks (4 x 7 - 1 = 27 days) every day');

    my ($f0, $t0) = win('2026-08-22', 0, 0);
    ok($f0 eq '2026-08-17' && $t0 eq '2026-08-23',
       '0/0 is exactly the current week, Monday to Sunday');
    my ($f3, $t3) = win('2026-08-22', 3, 0);
    ok($f3 eq '2026-07-27' && $t3 eq '2026-08-23', '3 back reaches three whole weeks');

    # Every window edge must be a real Monday / Sunday by DB::_weekStart, not by
    # this suite's arithmetic — that is the "no third week-start implementation"
    # property, checked rather than asserted in a comment.
    my $edges = 1;
    for my $p (0 .. 3) {
        for my $f (0 .. 3) {
            for my $d (@WEEK) {
                my ($lo, $hi) = win($d, $p, $f);
                $edges = 0 unless Plugins::ListenBrainzFreshReleases::DB::_weekStart($lo) eq $lo;
                $edges = 0 unless Plugins::ListenBrainzFreshReleases::DB::_weekStart(
                                      T::_shiftDay($hi, 1)) eq T::_shiftDay($hi, 1);
            }
        }
    }
    ok($edges, 'every edge of every (past, future, weekday) window is a Monday / a Sunday');
}

print "\nSECTION 3 — THE FRIDAY TEST: the week's main drop survives the weekend\n";
print "-" x 74, "\n";
{
    # The regression this whole change exists to end. "Include earlier weeks" OFF
    # is the strictest setting there is, and Friday's releases must STILL be in
    # the window when the user browses on Saturday and on Sunday.
    $PREF{all_past} = 0;  $PREF{all_future} = 0;
    $PREF{weeks_past} = 1; $PREF{weeks_future} = 2;

    my $friday = '2026-08-21';
    my $kept   = 1;
    for my $i (0 .. $#WEEK) {
        my ($lo, $hi) = do { local $TODAY = $WEEK[$i]; T::sectionWindow('all') };
        next if $WEEK[$i] lt $friday;      # before Friday it hasn't come out yet
        $kept = 0 unless $friday ge $lo && $friday le $hi;
    }
    ok($kept, "a Friday release is still in All Releases on Friday, Saturday AND Sunday "
            . "with earlier weeks OFF");

    # ...and it drops out on the Monday, because the WEEK rolled — not because
    # midnight did. That is the boundary the old day window did not have.
    my ($nlo) = do { local $TODAY = '2026-08-24'; T::sectionWindow('all') };
    ok($friday lt $nlo, 'and it leaves the window on the next MONDAY, not at midnight');

    # The complementary half: a release due later this week is visible with the
    # later-weeks box off, because the current week is whole in both directions.
    $PREF{all_future} = 0;
    my (undef, $hi) = do { local $TODAY = '2026-08-18'; T::sectionWindow('all') };
    ok($hi eq '2026-08-23', "Thursday's unreleased album is in scope on Tuesday "
                          . "with later weeks OFF");
}

print "\nSECTION 4 — the LB days= parameter is DERIVED, and stays inside 27\n";
print "-" x 74, "\n";
{
    my ($d, $p, $f);

    ($d, $p, $f) = reqd('2026-08-22', 1, 2);
    ok($d == 15 && $p == 1 && $f == 1,
       'days is the WIDER side (15 forward beats 7 back), both flags on');

    # The one that reads like a bug and is the mechanism: the current week runs to
    # Sunday, so there are always days ahead of today to ask for.
    ($d, $p, $f) = reqd('2026-08-22', 1, 0);
    ok($f == 1, 'future=true even with ZERO later weeks — the current week runs to Sunday');
    ($d, $p, $f) = reqd('2026-08-22', 0, 2);
    ok($p == 1, 'past=true even with ZERO earlier weeks — the current week starts Monday');

    # Monday and Sunday are the days where one side collapses entirely.
    ($d, $p, $f) = reqd('2026-08-17', 0, 0);
    ok($p == 0 && $f == 1 && $d == 6, 'on a Monday with 0/0 there is no past side at all');
    ($d, $p, $f) = reqd('2026-08-23', 0, 0);
    ok($p == 1 && $f == 0 && $d == 6, 'on a Sunday with 0/0 there is no future side at all');

    my ($max, $zero) = (0, 0);
    for my $wp (0 .. 3) {
        for my $wf (0 .. 3) {
            next if $wp + $wf > T::WEEKS_MAX_SIDE();
            for my $day (@WEEK) {
                my ($n) = reqd($day, $wp, $wf);
                $max  = $n if $n > $max;
                $zero++ if $n < 1;
            }
        }
    }
    ok($max == 27, "the widest days= any legal window can ask for is 27 (got $max)");
    ok(!$zero, 'days= is never 0 — a 0-day fetch would answer with nothing');
}

print "\nSECTION 5 — the per-section gates, on the defaults Plugin.pm actually ships\n";
print "-" x 74, "\n";
{
    # Derived from $prefs->init, NOT restated: a hand-copied default is exactly how
    # foryou_future came to be read as `// 0` in four places and `// 1` in warmFeeds.
    my %init = $plugin_src =~ /^\s{4}(foryou_past|foryou_future|all_past|all_future|muspy_future|weeks_past|weeks_future)\s*=>\s*(\d+)/mg;
    ok(keys(%init) == 7, 'all seven window prefs are still initialised in Plugin.pm');
    ok(($init{weeks_past} // -1) == 1 && ($init{weeks_future} // -1) == 2,
       'the shipped window is 1 week back / 2 ahead');

    my $gateOK = 1;
    while ($api_src =~ /^\s{4}(foryou|all|muspy)\s*=>\s*\[\s*'(\w+)',\s*(\d),\s*'(\w+)',\s*(\d)\s*\],/mg) {
        my ($pfx, $pk, $pd, $fk, $fd) = ($1, $2, $3, $4, $5);
        # muspy borrows For You's past gate and swaps in its own future gate.
        $gateOK = 0 if exists $init{$pk} && $init{$pk} != $pd;
        $gateOK = 0 if exists $init{$fk} && $init{$fk} != $fd;
    }
    ok($gateOK, 'every gate fallback in %WEEK_GATES matches the pref default in Plugin.pm');

    %PREF = (weeks_past => 1, weeks_future => 2);   # gates all UNSET -> defaults
    ok("@{[ secw('2026-08-22', 'foryou') ]}" eq '1 2',
       'For You defaults to BOTH sides on (foryou_future is // 1, not // 0)');
    ok("@{[ secw('2026-08-22', 'all') ]}" eq '1 0',
       'All Releases defaults to earlier weeks only (all_future is // 0)');
    ok("@{[ secw('2026-08-22', 'muspy') ]}" eq '1 2',
       'MuSpy defaults to both sides — muspy_future is // 1 like For You');

    # A gate is a per-section ZERO, never a change to the shared week counts.
    $PREF{all_past} = 0;
    ok("@{[ secw('2026-08-22', 'all') ]}" eq '0 0', 'unticking all_past zeroes ALL Releases');
    ok("@{[ secw('2026-08-22', 'foryou') ]}" eq '1 2', '...and leaves For You untouched');

    %PREF = (weeks_past => 1, weeks_future => 2, foryou_future => 0, muspy_future => 1);
    ok("@{[ secw('2026-08-22', 'foryou') ]}" eq '1 0'
       && "@{[ secw('2026-08-22', 'muspy') ]}" eq '1 2',
       'MuSpy can still show upcoming when the LB For You future side is off');

    ok("@{[ T::sectionWeeks('nonsense') ]}" eq '0 0',
       'an unknown prefix yields no window rather than a default one');
}

print "\nSECTION 6 — one window helper, and one memo key\n";
print "-" x 74, "\n";
{
    # Refresh drops a key; the fetcher builds one. When they diverge, Refresh
    # re-fetches and then serves the copy it was meant to replace (0.9.141). Two
    # sites spelling out the same join is how that happens, so there is now one
    # builder and this asserts BOTH sites go through it — a textual comparison of
    # two joins would pass on the day someone added a third.
    my @mint = ($api_src =~ /_feedMemoKey\(/g);
    ok(scalar(() = $api_src =~ /^sub _feedMemoKey\b/mg) == 1 && scalar @mint == 4,
       'one builder, and its four call sites — both fetchers and both halves of '
       . 'clearFeedCache (found ' . scalar(@mint) . ' calls)');
    ok(scalar(() = $api_src =~ /'lbf:feed:(?:all|user):'/g) == 2,
       'the literal key prefixes appear ONLY inside that builder');

    # And behaviourally: the key the fetcher mints for a given (weeks) must be the
    # key clearFeedCache computes from the prefs that produced those weeks.
    {
        my $mk = grab($api_src, '_feedMemoKey');
        local $PREF{username} = 'simon';
        eval "package T; my \$prefs = bless {}, 'StubPrefs'; $mk 1;" or die $@;
        %PREF = (username => 'simon', weeks_past => 1, weeks_future => 2);
        my $minted  = T::_feedMemoKey('foryou', 'release_date', T::sectionWeeks('foryou'));
        my $dropped = T::_feedMemoKey('foryou', 'release_date', T::sectionWeeks('foryou'));
        ok($minted eq $dropped && $minted eq 'lbf:feed:user:simon|release_date|1|2',
           "the For You key round-trips through one builder ($minted)");
        ok(T::_feedMemoKey('all', 'release_date', 1, 0)
             eq 'lbf:feed:all:release_date|1|0|' . T::_today(),
           'the All Releases key still names today (the memo may; the store may not)');
    }

    # The point of sectionWeeks is that nothing else reads these prefs. A second
    # read site is how the old `days` + past/future sites came to disagree.
    my @stray = ($browse_src =~ /\$prefs->get\('(weeks_past|weeks_future)'\)/g);
    ok(!@stray, 'Browse.pm never reads the week prefs directly'
              . (@stray ? ' (found: ' . join(', ', @stray) . ')' : ''));
    # Comments deliberately NAME the retired prefs (that is what a historical note
    # is for), so strip them before looking — otherwise this assertion forces the
    # explanation to be deleted along with the code, which is the opposite of what
    # is wanted here.
    (my $browse_code = $browse_src) =~ s/^\s*#.*$//mg;
    ok($browse_code !~ /\bdays\b\s*=>/ && $browse_code !~ /get\('days'\)/
       && $browse_code !~ /muspy_future_months/,
       'no CODE in Browse.pm reads or passes the retired `days` / `muspy_future_months`');
    ok($browse_src !~ /^sub _dateShift\b/m,
       '_dateShift went with them — nothing computes dates outside the shared helpers');

    # The MuSpy merge must ride sectionWindow, not a private window of its own.
    my $merge = grab($browse_src, '_mergeMuSpy');
    ok($merge =~ /sectionWindow\('muspy'\)/,
       'the MuSpy merge windows on API::sectionWindow(\'muspy\')');
    ok($merge !~ /months|_dateShift/,
       '...and carries no month arithmetic of its own any more');

    # The tile subtitle states the span the feed will actually be asked for.
    my $span = grab($browse_src, '_windowSpan');
    ok($span =~ /sectionWindow/ && $span !~ /86400/,
       '_windowSpan reports the real window rather than recomputing one');
}

print "\nSECTION 7 — the settings form, and the sentinel that arms every checkbox\n";
print "-" x 74, "\n";
{
    my ($sentinel) = $settings_src =~ /if \(exists \$params->\{(pref_\w+)\}\) \{\s*\n\s*for my \$cb \(\@CHECKBOX_PREFS\)/;
    ok(defined $sentinel, 'the checkbox coercion is still guarded by a form sentinel');
    ok(defined $sentinel && $sentinel ne 'pref_days',
       'the sentinel is no longer the retired pref_days field');
    ok(defined $sentinel && $tmpl_src =~ /name="\Q$sentinel\E"/,
       "the sentinel ($sentinel) names a field settings.html actually posts");
    ok(defined $sentinel && $tmpl_src =~ /name="\Q$sentinel\E"[^>]*type="number"|type="number"[^>]*name="\Q$sentinel\E"/,
       'the sentinel is a number field — one the full form always submits, ticked or not');

    ok($tmpl_src !~ /pref_days|pref_muspy_future_months/,
       'the retired fields are gone from the template');
    ok($tmpl_src =~ /name="pref_weeks_past"[^>]*min="0"[^>]*max="3"/
       && $tmpl_src =~ /name="pref_weeks_future"[^>]*min="0"[^>]*max="3"/,
       'both week fields are present and bounded 0-3 in the form itself');

    my ($prefslist) = $settings_src =~ /sub prefs \{\s*return \(\$prefs, qw\((.*?)\)\);/s;
    ok($prefslist && $prefslist =~ /\bweeks_past\b/ && $prefslist =~ /\bweeks_future\b/,
       'both week prefs are in the prefs() list, so the base handler persists them');
    ok($prefslist && $prefslist !~ /\bdays\b/ && $prefslist !~ /muspy_future_months/,
       'the retired prefs are out of the prefs() list');
    ok($settings_src =~ /\$w\{weeks_future\} = \$max - \$w\{weeks_past\}/,
       'the save path applies the same past-first budget rule as API::_clampWeeks');

    # Every strings key the template asks for must exist, or the settings page
    # renders raw token names at the user.
    my $strings = slurp(File::Spec->catfile($PLUGDIR, 'strings.txt'));
    my @keys = $tmpl_src =~ /(?:title|desc)="(PLUGIN_LBF_\w+)"/g;
    my @miss = grep { $strings !~ /^\Q$_\E$/m } @keys;
    ok(!@miss, 'every PLUGIN_LBF_* key the settings template uses exists in strings.txt'
             . (@miss ? " (missing: @miss)" : ''));
    ok($strings !~ /^PLUGIN_LBF_DAYS$/m && $strings !~ /^PLUGIN_LBF_MUSPY_FUTURE_MONTHS$/m,
       'the retired strings are gone rather than left to rot');
}

printf("\n%s\n%d passed, %d failed\n", "=" x 74, $pass, $fail);
exit($fail ? 1 : 0);
