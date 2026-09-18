#!/usr/bin/env perl
#
# t_statsratelimit.pl — the follower stats path must not burst ListenBrainz.
#
#   perl tools/t_statsratelimit.pl
#
# THE BUG, measured live on 2026-08-22 with the 0.9.175 warm instrument:
#
#   trending_tracks   at 51.03   \
#   trending_month    at 51.06    >  all three within 50ms
#   trending_year     at 51.08   /
#   "Fetching following" x3, 25ms apart   <- none had cached before the next asked
#   39 of 39 stats requests -> 429 TOO MANY REQUESTS, inside 0.88s
#   -> "mapped 0 recordings", "aggregate 0 album(s)", People You Follow EMPTY
#
# Two independent causes, so two independent fixes, and either alone still breaks:
#
#   A. `_warmTrending` started all three builds at once. Each fans out at
#      FOLLOWER_FANOUT (10), so 30 requests went out together — ListenBrainz's
#      entire ~30-per-10s budget. Now chained.
#   B. `API::_getUserStats` had NO rate limiting at all. The backoff built in
#      0.9.165 (_lbWait/_lbNoteLimit/_lbIsRateLimited) was wired to
#      getReleaseGroupMetadata and nothing else, and a 429 was answered with []
#      — laundering a rate limit into "this follower has no listens", which is
#      "an empty result is never a fact" failing on a new path.
#
# ANTI-TEST (LBF_API= / LBF_BROWSE= at a mutated copy). Both were run, both red:
#   - drop the _lbWait check from _getUserStats            -> 1 red (section 1)
#   - fire the three builds in parallel again              -> 1 red (section 3)
#
# Section 3's first cut caught NEITHER: it used a span match that reached across
# the callback's closing brace, so it stayed green against a mutant that moved the
# chained call one line out of the callback — which IS the parallel bug. Anchored
# on the callback's own closing punctuation instead. A test for "X happens inside
# Y" must anchor on Y's boundary, or it only tests "X happens somewhere".
#
# Exit 0 = the burst cannot recur. Exit 1 = it can.
use strict;
use warnings;
use FindBin;
use File::Spec;

my $ROOT   = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, File::Spec->updir));
my $API    = $ENV{LBF_API}    || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'API.pm');
my $BROWSE = $ENV{LBF_BROWSE} || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Browse.pm');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $msg) = @_;
    die "t_statsratelimit: assertion called with no message — a bare m// or grep\n"
      . "has shifted the arguments. Wrap the condition in scalar().\n"
        unless defined $msg && length $msg;
    if ($cond) { $pass++; printf "  ok   %s\n", $msg }
    else       { $fail++; printf "  FAIL %s\n", $msg }
    return $cond ? 1 : 0;
}
sub section { printf "\n%s\n%s\n", $_[0], '-' x 74 }
sub slurp { open(my $f,'<:encoding(UTF-8)',$_[0]) or die "$_[0]: $!"; local $/; <$f> }
sub grab {
    my ($src, $name) = @_;
    $src =~ /^sub \Q$name\E\b\s*\{/mg or die "no sub $name\n";
    my $start = $-[0]; my $i = pos($src); my $d = 1;
    while ($i < length($src) && $d) { my $c = substr($src,$i++,1); $d++ if $c eq '{'; $d-- if $c eq '}' }
    pos($src) = undef;
    return substr($src, $start, $i - $start);
}

my $asrc = slurp($API);
my $bsrc = slurp($BROWSE);
my $stats = grab($asrc, '_getUserStats');
my $warm  = grab($bsrc, '_warmTrending');

# ---------------------------------------------------------------------------
section '1. THE STATS PATH RESPECTS THE SHARED RATE LIMIT';
# Source-level, because the point is that a collaborator IS REACHED — there is no
# return value that shows a request was withheld. Same argument as
# t_tokenfree.pl section 4.
{
    ok(scalar($stats =~ /_lbWait\(\)/),
       '_getUserStats waits on the SHARED deadline before requesting');
    ok(scalar($stats =~ /_lbIsRateLimited\(/),
       'it recognises a 429 as a rate limit, not a generic failure');
    ok(scalar($stats =~ /_lbNoteLimit\(/),
       'and records the deadline so other callers back off too');
    ok(scalar($stats =~ /LB_RETRY_MAX/),
       'the retry is BOUNDED — an uncapped retry is the 0.9.174 hosted-429 hang');

    # The retry must re-enter through the SAME wait, or the second attempt walks
    # straight back into the wall the first one hit.
    ok(scalar($stats =~ /setTimer\([^;]*\$self->\(\$self,\s*\$attempt \+ 1\)/s),
       'a 429 reschedules the whole request, so the retry re-checks the deadline');

    # 0.9.95: a self-capturing closure is an uncollectable reference cycle. This
    # sub now builds one per follower per build, so the cycle would leak steadily.
    ok(scalar($stats =~ /my \(\$self, \$attempt\) = \@_/),
       'the retry closure is passed to ITSELF (no self-capturing reference cycle)');

    # A rate limit must never be cached as an answer.
    my ($success_cache) = $stats =~ /(\$cache->set\([^;]*STATS_TTL[^;]*;)/;
    ok(scalar(defined $success_cache), 'a successful result is still cached');
    ok(scalar($stats !~ /_lbIsRateLimited[\s\S]{0,400}?\$cache->set/),
       'but the 429 branch caches NOTHING — an empty result is never a fact');
}

# ---------------------------------------------------------------------------
section '2. THE FIX IS SHARED, NOT COPIED';
# _lbWait/_lbNoteLimit keep ONE deadline for the whole plugin. If the stats path
# had its own, the two would take turns exhausting the budget for each other.
{
    my ($decl) = $asrc =~ /(my \$_lbBusyUntil\b[^\n]*)/;
    ok(scalar(defined $decl), 'there is exactly one rate-limit deadline variable');
    my $n = () = $asrc =~ /my \$_lbBusyUntil\b/g;
    ok(scalar($n == 1), "and only one declaration of it (found $n)");
    ok(scalar($asrc =~ /sub _lbWait/ && $asrc =~ /sub _lbNoteLimit/),
       'both helpers still live in API.pm, shared by every caller');
}

# ---------------------------------------------------------------------------
section '3. THE THREE FOLLOWER BUILDS RUN ONE AT A TIME';
# This is cause A, and it is the half that made the per-user caches useless:
# getFollowing was fetched three times because none had finished writing.
{
    # this_year must be reached from this_month's completion, not started beside it.
    ok(scalar($warm =~ /my \$albumsYear = sub \{/),
       'the year build is a named step, not a bare parallel call');
    # INSIDE the callback, not merely somewhere after it. The first cut used a
    # span match here and stayed green against a mutant that moved the call one
    # line out of the callback — i.e. back to running the two builds in parallel,
    # the exact bug this section exists to prevent. Anchor on the callback's own
    # closing punctuation so "inside" is actually asserted.
    ok(scalar($warm =~ /\$albumsYear->\(\);\s*\}, \$force\);/),
       'this_year is started from INSIDE this_month\'s completion callback');

    # and the tracks build must hand off to the albums chain.
    ok(scalar($warm =~ /_resolveTrending\(\$client,\s*undef,\s*\$force,\s*undef,\s*\$albumsMonth\)/),
       'trending_tracks hands off to the albums chain via the completion hook');

    # The no-player path must still advance the chain, or the section stalls for
    # anyone with no connected player.
    ok(scalar($warm =~ /no player[\s\S]{0,200}?\$albumsMonth->\(\)/),
       'the no-player path still advances the chain rather than stopping it');

    # Nothing may start a build outside the chain.
    my $starts = () = $warm =~ /_buildAlbumsData\(/g;
    ok(scalar($starts == 2), "exactly two album builds are started (found $starts)");
}

# ---------------------------------------------------------------------------
section '4. THE COMPLETION HOOK FIRES ON EVERY EXIT';
# A chain that only advanced on success would stall the whole section the first
# time a build found nothing — and "found nothing" is the common case here.
{
    my $rt = grab($bsrc, '_resolveTrending');
    ok(scalar($rt =~ /my \(\$client, \$callback, \$force, \$feat, \$onDone\) = \@_/),
       '_resolveTrending takes a completion hook distinct from its render callback');
    ok(scalar($rt =~ /return if \$fired\+\+/),
       'the hook is guarded so it can fire at most once');

    my $n = () = $rt =~ /\$finish->\(\)/g;
    # setup-required, cache hit, the empty branch, and the resolved path.
    ok(scalar($n >= 4), "it is called from every terminal point (found $n)");

    ok(scalar($rt =~ /PLUGIN_LBF_NO_TRENDING[\s\S]{0,200}?\$finish->\(\)/),
       'INCLUDING the empty branch — the common case must not stall the chain');
}

printf "\n%s\n%d passed, %d failed.\n", '=' x 74, $pass, $fail;
exit($fail ? 1 : 0);
