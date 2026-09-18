#!/usr/bin/env perl
#
# t_weekwindow.pl — the whole-week release window (0.9.185), set PER SECTION as a
# total and an upcoming count.
#
#   perl tools/t_weekwindow.pl
#
# WHAT THIS PROTECTS, AND WHY EACH ASSERTION EXISTS.
#
# The window used to be a rolling DAY count measured from today, and the bug that
# killed it is not a crash — it is a release quietly disappearing. The UI renders
# in whole Monday-to-Sunday weeks, but the window's edges landed on arbitrary
# days, so with no earlier weeks the current week's row held only today onwards
# and FRIDAY'S RELEASES were gone by Saturday. Section 3 is that exact scenario,
# run for every day of a real week: it is the assertion the feature exists for,
# and it is the one that goes red if anyone reintroduces a today-relative edge.
#
# The window is now two numbers per section — `<section>_weeks` (weeks shown in
# total, THIS WEEK COUNTED AS 1, max 4) and `<section>_upcoming` (how many of those
# are ahead). They replaced a shared weeks_past/weeks_future pair, four per-section
# past/future checkboxes and MuSpy's own future checkbox. The rest are the failure
# shapes around that:
#
#   - THE BUDGET MUST HOLD FROM BOTH DIRECTIONS. The prefs are clamped on save AND
#     at read time, because prefs.yaml is hand-editable and the values are
#     multiplied out into a date range. A suite that only tested the Settings
#     clamp would pass against a hand-edited 52. And the current week must ALWAYS
#     be in the window: upcoming can never swallow it.
#
#   - `future` MUST COME BACK TRUE WITH ZERO UPCOMING WEEKS. That reads like a bug
#     and is the mechanism behind whole weeks: the current week runs to Sunday, so
#     days ahead of today are always being asked for. Section 4 pins it so a future
#     tidy-up cannot "fix" it back into the half-week bug.
#
#   - THE DEFAULTS IN API's %WEEK_PREFS MUST AGREE WITH Plugin.pm's $prefs->init.
#     The old read sites DISAGREED — foryou_future fell back to `// 0` in four places
#     and `// 1` in warmFeeds — so a warm and a browse asked ListenBrainz two
#     different questions. Section 5 derives the expected defaults FROM Plugin.pm.
#
#   - THE SECTIONS ARE INDEPENDENT, AND MUSPY IS NOT A SECTION. All Releases can
#     now differ from For You, and MuSpy rides For You's window exactly — it must
#     never be shown past the four weeks however far ahead MuSpy announces.
#
#   - THE MEMO KEY THE FETCHER BUILDS AND THE ONE clearFeedCache DROPS MUST BE THE
#     SAME KEY (the 0.9.141 Refresh bug). Section 6.
#
#   - THE CHECKBOX-COERCION SENTINEL MUST NAME A FIELD THE FORM ACTUALLY POSTS.
#     It was `pref_days`, then `pref_weeks_past`; both fields are gone. Removing the
#     field without moving the sentinel breaks EVERY checkbox on the settings page
#     at once, silently. Section 7 ties the sentinel in Settings.pm to a field in
#     settings.html.
#
# ANTI-TEST (do this after changing anything here — a green baseline against a
# window helper that ignores its arguments is worth nothing):
#
#   cp ListenBrainzFreshReleases/API.pm /tmp/API.pm
#   # in /tmp/API.pm make _feedWindow return ($today, $today)
#   LBF_API=/tmp/API.pm perl tools/t_weekwindow.pl     # must go RED (sections 2-4)
#   # or drop clampSectionWeeks' `$upcoming = $weeks - 1` line   # RED (section 1)
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
my $SETTINGS = $ENV{LBF_SETTINGS} || File::Spec->catfile($PLUGDIR, 'Settings.pm');
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
    my $depth = 1;
    my $end   = length($src);
    # BRACE-SCAN BY REGEX, NOT substr()-PER-CHARACTER — substr() on a character
    # string is not O(1), and a per-character walk of Browse.pm reads as a hang.
    while ($src =~ /([{}])/g) {
        $1 eq '{' ? $depth++ : $depth--;
        next if $depth;
        $end = pos($src);
        last;
    }
    pos($src) = undef;
    return substr($src, $start, $end - $start) . "\n";
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
# The date arithmetic is lifted from DB.pm rather than reimplemented here: a suite
# that asserts a Monday it worked out itself asserts nothing about the Monday the
# plugin computes.
# ---------------------------------------------------------------------------
{
    no strict 'refs';
    for my $s (qw(_weekStart _toDays _fromDays)) {
        eval "package Plugins::ListenBrainzFreshReleases::DB; " . grab($db_src, $s) . "1;"
            or die "DB::$s: $@";
    }
    $INC{'Plugins/ListenBrainzFreshReleases/DB.pm'} = __FILE__;
}

# Stub prefs: a plain hash, so a MISSING pref really is undef and every default in
# the lifted code is exercised rather than papered over.
my %PREF;
{
    package StubPrefs;
    sub get { $PREF{ $_[1] } }
    sub set { $PREF{ $_[1] } = $_[2] }
}

# The constants, the pref table and the helpers, verbatim from API.pm.
{
    my $code = "package T; use strict; use warnings;\n"
             . "my \$prefs = bless {}, 'StubPrefs';\n";
    for my $c (qw(WEEKS_MAX_SIDE WEEKS_MAX WEEKS_PAST_DEFAULT WEEKS_FUTURE_DEFAULT)) {
        $api_src =~ /^(use constant \Q$c\E\s*=>.*?;)/m or die "no constant $c\n";
        $code .= "$1\n";
    }
    $api_src =~ /^(my %WEEK_PREFS = \(.*?\n\);)/ms or die "no %WEEK_PREFS\n";
    $code .= "$1\n";
    $code .= grab($api_src, $_) for qw(_clampWeeks _feedWindow _feedRequestDays
                                       _shiftDay _spanDays clampSectionWeeks
                                       sectionWeekPrefs sectionWeeks sectionWindow);
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
# across the window call AND the derivation.
sub reqd { my $d = shift; local $TODAY = $d; T::_feedRequestDays(T::_feedWindow(@_)) }
sub clamp { join ' ', T::clampSectionWeeks(@_) }

# 2026-08-17 is a Monday; 21st Friday, 22nd Saturday, 23rd Sunday.
my @WEEK = qw(2026-08-17 2026-08-18 2026-08-19 2026-08-20 2026-08-21 2026-08-22 2026-08-23);

print "\nSECTION 1 — (weeks, upcoming): the four-week budget, and this week always in\n";
print "-" x 74, "\n";
{
    ok(T::WEEKS_MAX() == 4, 'the budget is four weeks, the current week counted as 1');
    ok(clamp(undef, undef, 4, 2) eq '4 2', 'missing prefs fall back to the section default');
    ok(clamp(1, 0, 4, 2) eq '1 0', '1 week, 0 upcoming is legal — the current week alone');
    ok(clamp(4, 3, 4, 2) eq '4 3', '4 with 3 upcoming is legal — this week + the next three');
    ok(clamp(2, 3, 4, 2) eq '2 1',
       'upcoming is held to weeks-1: 2 weeks can have at most 1 upcoming');
    ok(clamp(1, 3, 4, 2) eq '1 0', '...so with 1 week there is never an upcoming one');
    ok(clamp(0, 0, 4, 2) eq '1 0', 'a 0 is read as 1 — the current week is never hidden');
    ok(clamp(52, 52, 4, 2) eq '4 3', 'a hand-edited 52/52 cannot produce a year-wide window');
    ok(clamp('banana', '-4', 2, 0) eq '2 0', 'garbage and a negative both fall back to the defaults');
    ok(clamp(' 3 ', '1', 4, 2) eq '3 1', 'whitespace around a number from the form is tolerated');

    # The invariants, over the whole input space rather than at listed points.
    my $bad = 0;
    for my $w (-1 .. 8) {
        for my $u (-1 .. 8) {
            my ($cw, $cu) = T::clampSectionWeeks($w, $u, 4, 2);
            $bad++ if $cw < 1 || $cw > 4 || $cu < 0 || $cu > $cw - 1;
        }
    }
    ok(!$bad, 'no (weeks, upcoming) in -1..8 x -1..8 escapes 1..4 / 0..weeks-1');

    # And the derived (past, future) pair is always a legal window.
    my $pairBad = 0;
    for my $w (1 .. 4) {
        for my $u (0 .. $w - 1) {
            %PREF = (all_weeks => $w, all_upcoming => $u);
            my ($p, $f) = T::sectionWeeks('all');
            $pairBad++ unless $p >= 0 && $f >= 0 && 1 + $p + $f == $w && $f == $u
                           && $p + $f <= T::WEEKS_MAX_SIDE();
        }
    }
    ok(!$pairBad, 'every legal (weeks, upcoming) maps to past = weeks-1-upcoming, future = upcoming');
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
    # The regression this whole change exists to end. One week (this week only) is
    # the strictest setting there is, and Friday's releases must STILL be in the
    # window when the user browses on Saturday and on Sunday.
    %PREF = (all_weeks => 1, all_upcoming => 0);

    my $friday = '2026-08-21';
    my $kept   = 1;
    for my $i (0 .. $#WEEK) {
        my ($lo, $hi) = do { local $TODAY = $WEEK[$i]; T::sectionWindow('all') };
        next if $WEEK[$i] lt $friday;      # before Friday it hasn't come out yet
        $kept = 0 unless $friday ge $lo && $friday le $hi;
    }
    ok($kept, "a Friday release is still in All Releases on Friday, Saturday AND Sunday "
            . "with Weeks to show = 1");

    # ...and it drops out on the Monday, because the WEEK rolled — not midnight.
    my ($nlo) = do { local $TODAY = '2026-08-24'; T::sectionWindow('all') };
    ok($friday lt $nlo, 'and it leaves the window on the next MONDAY, not at midnight');

    # The complementary half: a release due later this week is visible with no
    # upcoming weeks, because the current week is whole in both directions.
    my (undef, $hi) = do { local $TODAY = '2026-08-18'; T::sectionWindow('all') };
    ok($hi eq '2026-08-23', "Thursday's unreleased album is in scope on Tuesday "
                          . "with 0 upcoming weeks");
}

print "\nSECTION 4 — the LB days= parameter is DERIVED, and stays inside 27\n";
print "-" x 74, "\n";
{
    my ($d, $p, $f);

    ($d, $p, $f) = reqd('2026-08-22', 1, 2);
    ok($d == 15 && $p == 1 && $f == 1,
       'days is the WIDER side (15 forward beats 7 back), both flags on');

    ($d, $p, $f) = reqd('2026-08-22', 1, 0);
    ok($f == 1, 'future=true even with ZERO upcoming weeks — the current week runs to Sunday');
    ($d, $p, $f) = reqd('2026-08-22', 0, 2);
    ok($p == 1, 'past=true even with ZERO earlier weeks — the current week starts Monday');

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

print "\nSECTION 5 — per-section prefs, on the defaults Plugin.pm actually ships\n";
print "-" x 74, "\n";
{
    # Derived from $prefs->init, NOT restated: a hand-copied default is exactly how
    # foryou_future came to be read as `// 0` in four places and `// 1` in warmFeeds.
    my %init = $plugin_src =~ /^\s{4}(foryou_weeks|foryou_upcoming|all_weeks|all_upcoming)\s*=>\s*(\d+)/mg;
    ok(keys(%init) == 4, 'all four window prefs are initialised in Plugin.pm');
    ok(($init{foryou_weeks} // -1) == 2 && ($init{foryou_upcoming} // -1) == 1,
       'For You ships 2 weeks with 1 upcoming — this week + next week');
    ok(($init{all_weeks} // -1) == 2 && ($init{all_upcoming} // -1) == 1,
       'All Releases ships 2 weeks with 1 upcoming — this week + next week');

    my ($rows, $agree) = (0, 1);
    while ($api_src =~ /^\s{4}(foryou|all)\s*=>\s*\[\s*'(\w+)',\s*(\d),\s*'(\w+)',\s*(\d)\s*\],/mg) {
        my ($pfx, $wk, $wd, $uk, $ud) = ($1, $2, $3, $4, $5);
        $rows++;
        $agree = 0 unless ($init{$wk} // -1) == $wd && ($init{$uk} // -1) == $ud;
    }
    ok($rows == 2 && $agree, 'every default in %WEEK_PREFS matches the pref default in Plugin.pm');

    %PREF = ();   # everything UNSET -> the table's defaults
    ok("@{[ secw('2026-08-22', 'foryou') ]}" eq '0 1', 'For You unset reads as 0 back / 1 ahead');
    ok("@{[ secw('2026-08-22', 'all') ]}" eq '0 1', 'All Releases unset reads as 0 back / 1 ahead');

    # THE POINT OF THE CHANGE: the sections are independent.
    %PREF = (foryou_weeks => 4, foryou_upcoming => 3, all_weeks => 3, all_upcoming => 0);
    ok("@{[ secw('2026-08-22', 'foryou') ]}" eq '0 3'
       && "@{[ secw('2026-08-22', 'all') ]}" eq '2 0',
       'For You and All Releases each read their OWN window');

    # The retired prefs are inert, whatever a pre-change prefs.yaml still holds.
    %PREF = (weeks_past => 3, weeks_future => 0, foryou_past => 0, foryou_future => 0,
             all_past => 0, all_future => 1, muspy_future => 1);
    # Read, they would give For You '3 0' and All Releases '0 0' — both differ from the defaults.
    ok("@{[ secw('2026-08-22', 'foryou') ]}" eq '0 1'
       && "@{[ secw('2026-08-22', 'all') ]}" eq '0 1',
       'the retired weeks_*/*_past/*_future/muspy_future prefs no longer move the window');

    # MuSpy is not a section: it has no window to diverge with.
    ok("@{[ T::sectionWeeks('muspy') ]}" eq '0 0' && !T::sectionWeekPrefs('muspy'),
       'MuSpy has no window prefs of its own');
    ok("@{[ T::sectionWeeks('nonsense') ]}" eq '0 0',
       'an unknown prefix yields no window rather than a default one');
    ok($api_src !~ /%WEEK_GATES/ && $api_src !~ /get\('(?:weeks_past|weeks_future|muspy_future)'\)/,
       'the old gate table and week-pref reads are gone from API.pm');
}

print "\nSECTION 6 — one window helper, one memo key, and MuSpy on For You's window\n";
print "-" x 74, "\n";
{
    my @mint = ($api_src =~ /_feedMemoKey\(/g);
    ok(scalar(() = $api_src =~ /^sub _feedMemoKey\b/mg) == 1 && scalar @mint == 4,
       'one builder, and its four call sites — both fetchers and both halves of '
       . 'clearFeedCache (found ' . scalar(@mint) . ' calls)');
    ok(scalar(() = $api_src =~ /'lbf:feed:(?:all|user):'/g) == 2,
       'the literal key prefixes appear ONLY inside that builder');

    {
        my $mk = grab($api_src, '_feedMemoKey');
        eval "package T; my \$prefs = bless {}, 'StubPrefs'; $mk 1;" or die $@;
        %PREF = (username => 'simon', foryou_weeks => 4, foryou_upcoming => 2);
        my $minted  = T::_feedMemoKey('foryou', 'release_date', T::sectionWeeks('foryou'));
        my $dropped = T::_feedMemoKey('foryou', 'release_date', T::sectionWeeks('foryou'));
        ok($minted eq $dropped
              && $minted eq 'lbf:feed:user:simon|release_date|1|2|' . T::_today(),
           "the For You key round-trips through one builder ($minted)");
        ok(T::_feedMemoKey('all', 'release_date', 1, 0)
             eq 'lbf:feed:all:release_date|1|0|' . T::_today(),
           'the All Releases key still names today (the memo may; the store may not)');
    }

    # The point of sectionWeeks is that nothing else reads these prefs.
    my @stray = ($browse_src =~ /\$prefs->get\('((?:foryou|all)_(?:weeks|upcoming)|weeks_past|weeks_future|muspy_future)'\)/g);
    ok(!@stray, 'Browse.pm never reads the week prefs directly'
              . (@stray ? ' (found: ' . join(', ', @stray) . ')' : ''));
    (my $browse_code = $browse_src) =~ s/^\s*#.*$//mg;
    ok($browse_code !~ /\bdays\b\s*=>/ && $browse_code !~ /get\('days'\)/
       && $browse_code !~ /muspy_future/,
       'no CODE in Browse.pm reads or passes `days`, `muspy_future_months` or `muspy_future`');
    ok($browse_code !~ /sectionWindow\('muspy'\)/,
       'nothing in Browse.pm asks for a MuSpy window any more');

    # MuSpy rows are For You rows.
    my $merge = grab($browse_src, '_mergeMuSpy');
    ok($merge =~ /sectionWindow\('foryou'\)/,
       'the MuSpy merge windows on API::sectionWindow(\'foryou\')');
    my $bounds = grab($browse_src, '_sectionBounds');
    ok($bounds =~ /sectionWindow\(\$section\)/ && $bounds !~ /muspy/,
       '_sectionBounds is the section window, with no MuSpy union');
    ok($browse_code =~ /my \$shown = _filterForYou\(_mergeMuSpy\(\[\], \$_\[0\]\)\);\s*_warmCovers\(\$shown, 'muspy'\);\s*_queueReleaseDetails\(\$shown, 'muspy'\);/,
       'the MuSpy warm prepares only the rows inside the For You window');

    my $span = grab($browse_src, '_windowSpan');
    ok($span =~ /_sectionBounds/ && $span !~ /86400/,
       '_windowSpan reports the real window rather than recomputing one');
}

print "\nSECTION 7 — the settings form, and the sentinel that arms every checkbox\n";
print "-" x 74, "\n";
{
    my ($sentinel) = $settings_src =~ /if \(exists \$params->\{(pref_\w+)\}\) \{\s*\n\s*for my \$cb \(\@CHECKBOX_PREFS\)/;
    ok(defined $sentinel, 'the checkbox coercion is still guarded by a form sentinel');
    ok(defined $sentinel && $sentinel !~ /^pref_(?:days|weeks_past)$/,
       'the sentinel is not a retired field (pref_days / pref_weeks_past)');
    ok(defined $sentinel && $tmpl_src =~ /name="\Q$sentinel\E"/,
       "the sentinel (" . ($sentinel // 'none') . ") names a field settings.html actually posts");
    ok(defined $sentinel && $tmpl_src =~ /type="number"[^>]*name="\Q$sentinel\E"/,
       'the sentinel is a number field — one the full form always submits, ticked or not');

    ok($tmpl_src !~ /pref_days|pref_muspy_future|pref_weeks_past|pref_weeks_future|pref_(?:foryou|all)_(?:past|future)\b/,
       'the retired fields are gone from the template');
    my $fieldsOK = 1;
    for my $s (qw(foryou all)) {
        $fieldsOK = 0 unless $tmpl_src =~ /name="pref_${s}_weeks"[^>]*min="1"[^>]*max="4"/
                          && $tmpl_src =~ /name="pref_${s}_upcoming"[^>]*min="0"[^>]*max="3"/;
    }
    ok($fieldsOK, 'both sections have Weeks to show (1-4) and Upcoming weeks (0-3) fields');

    my ($prefslist) = $settings_src =~ /sub prefs \{\s*return \(\$prefs, qw\((.*?)\)\);/s;
    ok($prefslist && $prefslist =~ /\bforyou_weeks\b/ && $prefslist =~ /\bforyou_upcoming\b/
       && $prefslist =~ /\ball_weeks\b/ && $prefslist =~ /\ball_upcoming\b/,
       'all four week prefs are in the prefs() list, so the base handler persists them');
    ok($prefslist && $prefslist !~ /\b(?:days|weeks_past|weeks_future|muspy_future|foryou_past|foryou_future|all_past|all_future)\b/
       && $prefslist !~ /muspy_future_months/,
       'the retired prefs are out of the prefs() list');
    my ($cbList) = $settings_src =~ /my \@CHECKBOX_PREFS = \((.*?)\);/s;
    ok($cbList && $cbList !~ /_past\b|_future\b/,
       'no retired past/future gate is still coerced as a checkbox');
    ok($settings_src =~ /can\('clampSectionWeeks'\)/ && $settings_src =~ /sectionWeekPrefs\(\$section\)/,
       'the save path clamps through API::clampSectionWeeks, the same rule as the read');

    my $strings = slurp(File::Spec->catfile($PLUGDIR, 'strings.txt'));
    my @keys = $tmpl_src =~ /(?:title|desc)="(PLUGIN_LBF_\w+)"/g;
    my @miss = grep { $strings !~ /^\Q$_\E$/m } @keys;
    ok(!@miss, 'every PLUGIN_LBF_* key the settings template uses exists in strings.txt'
             . (@miss ? " (missing: @miss)" : ''));
    my @retired = grep { $strings =~ /^\Q$_\E$/m }
        qw(PLUGIN_LBF_DAYS PLUGIN_LBF_MUSPY_FUTURE_MONTHS PLUGIN_LBF_MUSPY_FUTURE
           PLUGIN_LBF_WEEKS_PAST PLUGIN_LBF_WEEKS_FUTURE PLUGIN_LBF_FORYOU_PAST
           PLUGIN_LBF_FORYOU_FUTURE PLUGIN_LBF_ALL_PAST PLUGIN_LBF_ALL_FUTURE);
    ok(!@retired, 'the retired strings are gone rather than left to rot'
                . (@retired ? " (still there: @retired)" : ''));
}

print "\nSECTION 8 — Settings::handler RUNS: clamps the form, keeps stored values, reaches the save\n";
print "-" x 74, "\n";
{
    # A settings handler that dies part way still RENDERS a half-filled page, and
    # `perl -c` plus source regexes cannot see that. So load the REAL Settings.pm
    # against minimal LMS stubs and DRIVE it. The API half is the real clamp,
    # lifted from API.pm, so the save path and the read path share one rule here too.
    our %SPREF;
    our ($BASE_REACHED, $BASE_PARAMS);
    {
        no strict 'refs'; no warnings 'once';
        package Slim::Web::Settings;
        sub handler { $main::BASE_REACHED = 1; $main::BASE_PARAMS = { %{ $_[2] } }; 'rendered' }
        $INC{'Slim/Web/Settings.pm'} = __FILE__;
        package SStubPrefs;
        sub get { $main::SPREF{ $_[1] } }
        sub set { $main::SPREF{ $_[1] } = $_[2] }
        package SStubLog;
        sub AUTOLOAD { 1 }
        sub DESTROY {}
        package Slim::Utils::Prefs;
        sub import { *{ caller() . '::preferences' } = sub { bless {}, 'SStubPrefs' } }
        $INC{'Slim/Utils/Prefs.pm'} = __FILE__;
        package Slim::Utils::Log;
        sub import { *{ caller() . '::logger' } = sub { bless {}, 'SStubLog' } }
        $INC{'Slim/Utils/Log.pm'} = __FILE__;
        package Slim::Utils::Strings;
        sub import { *{ caller() . '::string' } = sub { $_[0] } }
        $INC{'Slim/Utils/Strings.pm'} = __FILE__;
    }
    {
        my $code = "package Plugins::ListenBrainzFreshReleases::API; use strict; use warnings;\n";
        for my $c (qw(WEEKS_MAX_SIDE WEEKS_MAX)) {
            $api_src =~ /^(use constant \Q$c\E\s*=>.*?;)/m or die "no constant $c\n";
            $code .= "$1\n";
        }
        $api_src =~ /^(my %WEEK_PREFS = \(.*?\n\);)/ms or die "no %WEEK_PREFS\n";
        $code .= "$1\n" . grab($api_src, 'clampSectionWeeks') . grab($api_src, 'sectionWeekPrefs') . "1;";
        eval $code or die "lifting API clamp: $@";
        $INC{'Plugins/ListenBrainzFreshReleases/API.pm'} = __FILE__;
    }
    my $loaded = do $SETTINGS;
    ok($loaded, 'the real Settings.pm loads against the stubs' . ($@ ? " ($@)" : ''));

    my $drive = sub {
        my ($params) = @_;
        ($BASE_REACHED, $BASE_PARAMS) = (0, undef);
        my $r = eval {
            Plugins::ListenBrainzFreshReleases::Settings->handler(undef, { saveSettings => 1, %$params }, sub {});
        };
        return ($r, $@);
    };

    # A full form POST: the sentinel is present, one value is over budget in each
    # section, and every checkbox is unticked (i.e. absent from the POST).
    %SPREF = (foryou_weeks => 4, foryou_upcoming => 2, all_weeks => 2, all_upcoming => 0);
    my ($r, $err) = $drive->({ pref_foryou_weeks => '2', pref_foryou_upcoming => '3',
                               pref_all_weeks => '9', pref_all_upcoming => '1' });
    ok(!$err && $BASE_REACHED, 'a full POST reaches SUPER::handler — the save actually runs'
                              . ($err ? " (died: $err)" : ''));
    my $p = $BASE_PARAMS || {};
    ok(($p->{pref_foryou_weeks} // '') eq '2' && ($p->{pref_foryou_upcoming} // '') eq '1',
       'For You 2 weeks with 3 upcoming is saved as 2 with 1 — the current week is kept');
    ok(($p->{pref_all_weeks} // '') eq '4' && ($p->{pref_all_upcoming} // '') eq '1',
       'All Releases 9 weeks is saved as the four-week budget, its upcoming untouched');
    ok(exists $p->{pref_foryou_various} && $p->{pref_foryou_various} eq '0'
       && exists $p->{pref_play_via} && $p->{pref_play_via} eq '0',
       'the sentinel armed the checkbox coercion: unticked boxes are stored as an explicit 0');

    # A PARTIAL POST: no week fields at all. Stored values must survive, and the
    # checkboxes must NOT be coerced (an absent box is not an unticked one here).
    %SPREF = (foryou_weeks => 3, foryou_upcoming => 1, all_weeks => 1, all_upcoming => 0);
    ($r, $err) = $drive->({ pref_username => 'simon' });
    $p = $BASE_PARAMS || {};
    ok(!$err && $BASE_REACHED, 'a partial POST still reaches the save');
    ok(($p->{pref_foryou_weeks} // '') eq '3' && ($p->{pref_foryou_upcoming} // '') eq '1'
       && ($p->{pref_all_weeks} // '') eq '1' && ($p->{pref_all_upcoming} // '') eq '0',
       'a POST without the week fields keeps the STORED windows, not the defaults');
    ok(!exists $p->{pref_foryou_various},
       '...and leaves the checkboxes alone, because the sentinel was absent');

    # An emptied field is not a zero.
    %SPREF = (foryou_weeks => 4, foryou_upcoming => 2, all_weeks => 3, all_upcoming => 1);
    ($r, $err) = $drive->({ pref_foryou_weeks => '4', pref_foryou_upcoming => '2',
                            pref_all_weeks => '', pref_all_upcoming => '1' });
    $p = $BASE_PARAMS || {};
    ok(($p->{pref_all_weeks} // '') eq '3' && ($p->{pref_all_upcoming} // '') eq '1',
       'a field cleared in the form keeps its stored value rather than becoming 0 or a default');
}

printf("\n%s\n%d passed, %d failed\n", "=" x 74, $pass, $fail);
exit($fail ? 1 : 0);
