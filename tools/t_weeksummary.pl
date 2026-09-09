#!/usr/bin/env perl
#
# t_weeksummary.pl — the root/home All Releases menus use indexed week summaries,
# and a week payload is not thawed until that week is selected.

use strict;
use warnings;
use FindBin;
use File::Spec;

my $ROOT = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, File::Spec->updir));
my $API  = File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'API.pm');
my $BR   = File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Browse.pm');

sub slurp {
    open(my $fh, '<:encoding(UTF-8)', $_[0]) or die "$_[0]: $!";
    local $/;
    return <$fh>;
}

sub grab {
    my ($src, $name) = @_;
    $src =~ /^sub \Q$name\E\b\s*\{/mg or die "no $name\n";
    my $start = $-[0];
    my $depth = 1;
    while ($src =~ /([{}])/g) {
        $1 eq '{' ? $depth++ : $depth--;
        next if $depth;
        my $out = substr($src, $start, pos($src) - $start) . "\n";
        pos($src) = undef;
        return $out;
    }
    die "unterminated $name\n";
}

my $api = slurp($API);
my $br  = slurp($BR);
my ($pass, $fail) = (0, 0);
sub ok {
    my ($v, $msg) = @_;
    if ($v) { $pass++; print "  PASS  $msg\n" }
    else    { $fail++; print "  FAIL  $msg\n" }
}

print "\nCHEAP ROOT SUMMARY\n", '-' x 74, "\n";
{
    my ($ttl) = $api =~ /^(use constant FEED_MEMO_TTL\s*=>.*?;)/m;
    my $code = q{
package Plugins::ListenBrainzFreshReleases::DB;
our ($COVERAGE, $WEEKS, $WEEK_SCANS, $WEEK_ROWS, $WEEK_READS, $GENERATION);
sub feedCoverage     { $COVERAGE }
sub feedWeeks        { $WEEK_SCANS++; $WEEKS }
sub feedWeekReleases { $WEEK_READS++; $WEEK_ROWS }
sub feedGeneration   { $GENERATION }

package WeekAPI;
use constant FEED_STALE_AFTER => 86400;
our (%FEED_MEMO, @FETCHES, @EVENTS);
sub _allFeedRequest {
    return { feed => 'all', from => '2026-09-07', to => '2026-09-27',
             memoKey => 'all-main', url => 'https://example.invalid/feed' };
}
sub _fetchReleaseFeed { push @FETCHES, { @_ }; push @EVENTS, 'fetch' }
} . "$ttl\n"
      . grab($api, '_memoGet')
      . grab($api, '_memoSet')
      . grab($api, 'getFreshReleaseWeeksAll')
      . grab($api, 'getFreshReleasesAllWeek') . "1;\n";
    eval $code or die "week API eval: $@";

    no warnings 'once';
    $Plugins::ListenBrainzFreshReleases::DB::GENERATION = 3;
    $Plugins::ListenBrainzFreshReleases::DB::WEEKS = [
        { week_start => '2026-09-14', count => 120 },
        { week_start => '2026-09-07', count => 140 },
    ];
    $Plugins::ListenBrainzFreshReleases::DB::COVERAGE = {
        any => 1, complete => 1, ok_at => time(),
    };
    $Plugins::ListenBrainzFreshReleases::DB::WEEK_SCANS = 0;
    @WeekAPI::FETCHES = @WeekAPI::EVENTS = ();
    my $got;
    WeekAPI::getFreshReleaseWeeksAll(undef,
        onDone => sub { $got = shift; push @WeekAPI::EVENTS, 'done' });
    ok($got == $Plugins::ListenBrainzFreshReleases::DB::WEEKS,
       'a fresh stored feed returns its compact week rows');
    ok(!@WeekAPI::FETCHES, 'a fresh summary starts no HTTP request');
    WeekAPI::getFreshReleaseWeeksAll(undef, onDone => sub {});
    ok($Plugins::ListenBrainzFreshReleases::DB::WEEK_SCANS == 1,
       'repeated root walks reuse the generation-backed summary');

    $Plugins::ListenBrainzFreshReleases::DB::COVERAGE->{ok_at} = time() - 2 * 86400;
    @WeekAPI::FETCHES = @WeekAPI::EVENTS = ();
    WeekAPI::getFreshReleaseWeeksAll(undef,
        onDone => sub { push @WeekAPI::EVENTS, 'done' });
    ok(join(',', @WeekAPI::EVENTS) eq 'done,fetch',
       'a stale summary renders before detached revalidation starts');

    $Plugins::ListenBrainzFreshReleases::DB::COVERAGE = { any => 0, complete => 0, ok_at => 0 };
    $Plugins::ListenBrainzFreshReleases::DB::WEEKS = [];
    @WeekAPI::FETCHES = @WeekAPI::EVENTS = ();
    my $cold = 'unset';
    WeekAPI::getFreshReleaseWeeksAll(undef,
        onDone => sub { $cold = shift; push @WeekAPI::EVENTS, 'done' });
    ok(ref $cold eq 'ARRAY' && !@$cold && join(',', @WeekAPI::EVENTS) eq 'done,fetch',
       'a cold store answers empty immediately and fills behind the fallback tile');

    %WeekAPI::FEED_MEMO = ();
    $Plugins::ListenBrainzFreshReleases::DB::WEEK_ROWS = [
        { release_name => 'Only this week', release_date => '2026-09-15' },
    ];
    $Plugins::ListenBrainzFreshReleases::DB::WEEK_READS = 0;
    my ($one, $two);
    WeekAPI::getFreshReleasesAllWeek(undef, week_start => '2026-09-14',
        onDone => sub { $one = shift });
    WeekAPI::getFreshReleasesAllWeek(undef, week_start => '2026-09-14',
        onDone => sub { $two = shift });
    ok($Plugins::ListenBrainzFreshReleases::DB::WEEK_READS == 1 && $one == $two,
       'a selected week is decoded once and then reused by generation');

    my $bad = 0;
    WeekAPI::getFreshReleasesAllWeek(undef, week_start => '../all',
        onDone => sub {}, onError => sub { $bad++ });
    ok($bad == 1 && $Plugins::ListenBrainzFreshReleases::DB::WEEK_READS == 1,
       'an invalid week cannot broaden into a whole-feed read');
}

print "\nBROWSE ROUTING\n", '-' x 74, "\n";
{
    my $top  = grab($br, 'topLevel');
    my $home = grab($br, 'homeAllReleases');
    my $rows = grab($br, '_buildAllWeekItems');
    my $summary = grab($br, '_buildAllSummaryLanding');
    my $landing = grab($br, '_buildAllLanding');
    my $all  = grab($br, '_allSection');
    my $dedupe = grab($br, '_dedupeReleases');
    my $clear = grab($api, 'clearFeedCache');
    ok($top =~ /getFreshReleaseWeeksAll/ && $top !~ /getFreshReleasesAll\s*\(/,
       'the plugin root asks for week summaries, never the whole All Releases feed');
    ok($home =~ /getFreshReleaseWeeksAll/ && $home !~ /getFreshReleasesAll\s*\(/,
       'the Material home shelf uses the same cheap summary path');
    ok($rows =~ /getFreshReleasesAllWeek/,
       'only selecting a week asks for its release payloads');
    ok($rows =~ /itemActions\s*=>\s*\{\s*items\s*=>\s*_weekAction\(\$ws\)/s,
       'every shared week row carries an explicit natural-key action');
    ok($landing =~ /_buildAllWeekItems/ && $summary =~ /_buildAllWeekItems/,
       'full-feed fallback and indexed root/home carriers share the guarded row builder');
    ok($all =~ /_sortReleases\(_filterAll\(\$feed\),\s*0\)/
           && $rows =~ /_sortReleases\(_filterAll\(\$rels\),\s*0\)/,
       'full and exact-week All Releases paths use identical dedupe scope');
    ok($dedupe =~ /\$crossSource\s*&&\s*defined\s+\$j/,
       'MuSpy cross-date collapse is explicitly limited to merged For You data');
    ok($br !~ /TOPLEVEL_ALL_WAIT/,
       'the obsolete five-second root watchdog is gone');
    ok($clear =~ /_memoDropPrefix\(\$allKey\s*\.\s*':'\)/,
       'manual Refresh drops the summary and exact-week memo children');
}

print "\n", '=' x 74, "\n$pass passed, $fail failed.\n";
exit($fail ? 1 : 0);
