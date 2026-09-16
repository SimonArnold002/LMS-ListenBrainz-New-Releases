#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use Time::HiRes ();
our ($now,@timers,@http)=(100);
BEGIN {
    $INC{'Slim/Utils/Timers.pm'}=1; $INC{'Slim/Utils/Log.pm'}=1;
    *CORE::GLOBAL::time = sub { int $main::now };
}
{ no warnings 'redefine'; *Time::HiRes::time = sub () { $now } }
{
    package Slim::Utils::Timers;
    sub setTimer {my $t=[@_]; push @main::timers,$t; $t}
    sub killSpecific {$_[0][4]=1}
    package Slim::Utils::Log;
    sub import { no strict 'refs'; *{caller().'::logger'}=sub { bless {},'Log' } }
    package Log; sub info {} sub warn {} sub error {}
    package Cache;
    sub get { $_[0]{$_[1]} }
    sub set { $_[0]{$_[1]}=$_[2]; 1 }
    package Slim::Networking::SimpleAsyncHTTP;
    sub new { bless {ok=>$_[1],err=>$_[2]},$_[0] }
    sub get { $_[0]{url}=$_[1]; push @main::http,$_[0] }
    package Response;
    sub content { '{}' }
    sub code { $_[0]{code} // 200 }
    sub error { '429' }
}
require "$FindBin::Bin/../ListenBrainzFreshReleases/SingleFlight.pm";
$INC{'Plugins/ListenBrainzFreshReleases/SingleFlight.pm'}=1;
sub grab {
    my ($file,$name)=@_; open my $f,'<',"$FindBin::Bin/../ListenBrainzFreshReleases/$file.pm" or die $!;
    my $s=do {local $/;<$f>}; $s =~ /^(sub \Q$name\E \{.*?^\})/ms or die $name; $1;
}
sub advance {
    my $to=shift; my $n=0;
    while (1) {
        @timers=sort {$a->[1]<=>$b->[1]} grep {!$_->[4]} @timers;
        last unless @timers && $timers[0][1]<=$to;
        die 'spin' if ++$n>10000;
        my $t=shift @timers; $now=$t->[1]; $t->[2]->($t->[0],$t->[3]);
    }
    $now=$to;
}
{
    package A;
    our ($releaseDetailFlights,$releaseDetailNextAt,$until,$mirror);
    $releaseDetailNextAt=0; $until=0;
    our $cache=bless {},'Cache'; our $log=bless {},'Log';
    use constant USER_AGENT=>'test'; use constant MB_FOUND_TTL=>30*86400; use constant MB_EMPTY_TTL=>86400;
    sub _mbBase { $mirror ? 'http://mirror/' : 'https://musicbrainz.org/' }
    sub _mbThrottled { !$mirror }
    sub _mbWait { $until>$main::now ? $until-$main::now : 0 }
    sub _mbNoteOk {}
    sub _mbIsRateLimited { $_[0]->code==429 }
    sub _mbNoteLimit { $until=$main::now+5 }
    sub from_json { {} }
    sub _parseReleaseDetails { {media=>[]} }
    sub _handleError { $_[1]->('offline') }
    # The one MusicBrainz queue, as a pass-through: pacing and the 503 backoff are
    # the queue's job now and are pinned in tools/t_mbqueue.pl. This file pins that
    # getReleaseDetails coalesces and HANDS its request to the queue.
    our @queued;
    sub _mbGet { my ($url,$ok,$err)=@_; push @queued,$url; my $h=Slim::Networking::SimpleAsyncHTTP->new($ok,$err); $h->get($url) }
}
eval 'package A; no strict "vars"; '.grab('API','getReleaseDetails');die $@ if $@;
my (@answers,@errors);
A->getReleaseDetails('same',sub{push @answers,'warm'},sub{push @errors,shift});
A->getReleaseDetails('same',sub{push @answers,'browse'},sub{push @errors,shift});
is(scalar @http,1,'warm and foreground tracklist requests share one HTTP call');
$http[0]{ok}->(bless {},'Response');
is_deeply(\@answers,['warm','browse'],'both tracklist callers receive the result');
A->getReleaseDetails('same',sub{push @answers,'cached'},sub{});
is(scalar @http,1,'subsequent tracklist open reads the durable cache');
A->getReleaseDetails('second',sub{},sub{push @errors,shift});
is(scalar @A::queued,2,'every tracklist request goes through the one MusicBrainz queue');
is(scalar @http,2,'...with no private courtesy gap of its own layered on top');
unlike(grab('API','getReleaseDetails'), qr/releaseDetailNextAt|SimpleAsyncHTTP->new/,
       'getReleaseDetails builds no HTTP request and keeps no pacing clock of its own');
$http[1]{err}->(bless {code=>503},'Response');
is(scalar @errors,1,'a refused request still reaches the caller\'s error path');
A->getReleaseDetails('third',sub{},sub{});
# Watchdog followed by a new identical flight: late callbacks must not settle it.
advance(227);
A->getReleaseDetails('third',sub{push @answers,'new'},sub{});
my $fresh=$http[-1];
$http[2]{ok}->(bless {},'Response');
ok(!grep($_ eq 'new',@answers),'late old response cannot answer a replacement flight');
$fresh->{ok}->(bless {},'Response');
is($answers[-1],'new','replacement flight answers from its own response');
{
    package B;
    our ($albumDetailFlights,@searches);
    our $cache=bless {},'Cache'; our $log=bless {},'Log';
    use constant STREAM_SVC_TIMEOUT=>8; use constant STREAM_FOUND_TTL=>7*86400;
    use constant STREAM_NOMATCH_TTL=>86400; use constant MISS_RETRY_SCHEDULE=>[60,300];
    # Not what this suite is about: Spotify is never refusing here, so the retry
    # budget behaves exactly as it did before the back-off existed.
    use constant SPOTIFY_FREE_PASSES=>3; sub _spotifyBackingOff { 0 }
    sub _norm { lc($_[0] // '') }
    sub _cid { $_[0] }
    sub _streamId { $_[2] }
    sub _streamKey { $_[0] }
    sub _bcMatchItems { () }
    sub _orderedAdapters { map {{ name=>$_, run=>sub { push @searches,[$_[4],$_[5]] } }} qw(First Second) }
    sub _streamResult { $_[1] }
    sub _rebuildStreamItems { $_[0] }
    sub _cacheStream { $cache->set($_[0],{items=>$_[1]}) }
    sub _attachFavUrl {}
    sub _llRelType { '' }
    sub _missRetryAt { $main::now+60 }
    sub _artistAltNames { $_[2]->([]) }   # the alias pass has nothing to add here
}
eval 'package B; no strict "vars"; '.grab('Browse','_findPlayable');die $@ if $@;
my @results;
B::_findPlayable('player',sub{push @results,shift},'artist','album','id');
B::_findPlayable('player',sub{push @results,shift},'artist','album','id');
is(scalar @B::searches,2,'warm and foreground share one two-service album search');
$B::searches[0][1]->([{name=>'match'}]);
is(scalar @results,2,'highest-priority match answers both callers promptly');
is(${ $results[0]{_warm_pending} },1,'background still sees the slower service in flight');
$B::searches[1][1]->([]);
is(${ $results[0]{_warm_pending} },0,'slower service completion releases background tail');
my $tail;
B::_findPlayable('player',sub{ $tail=shift },'artist','album','other');
$B::searches[2][1]->([{name=>'match'}]);
advance($now+9);
# With no callback from Second, its own service timeout must drain the tail.
is(${ $tail->{_warm_pending} },0,'slower service timeout releases the background tail after early rendering');
done_testing();
