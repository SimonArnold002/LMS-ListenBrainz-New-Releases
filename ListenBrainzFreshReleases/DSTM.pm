package Plugins::ListenBrainzFreshReleases::DSTM;

# Don't Stop The Music propagators backed by ListenBrainz. Registers TWO mixers
# (each appears separately in Lyrion's DSTM picker), loaded by
# Plugin::postinitPlugin (mirrors HomeExtras.pm — NOT a separate LMS plugin):
#
#   * ListenBrainz Radio          — seeds from the artist of the track you were
#                                   last playing, fans out to similar artists
#                                   (labs similar-artists) and their top
#                                   recordings, and EVOLVES: each top-up reseeds
#                                   from where the music has drifted. This is the
#                                   "follow on from what's playing, then grow"
#                                   behaviour.
#   * ListenBrainz Recommended    — your personalised collaborative-filtering
#                                   recommendations (discovery pool), shuffled.
#
# NB: ListenBrainz's cf-recommendation `artist_type` (similar/raw/top) is ignored
# by the live API (all return the same list), so there's one Recommended mixer,
# not three. Tracks resolve library-FIRST (Browse::_resolveTracks 'first'): an
# owned copy is preferred, otherwise Qobuz/Tidal/Bandcamp. A per-player guard
# ensures no track repeats within a session.

use strict;
use warnings;

use List::Util qw(shuffle);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;

my $log   = logger('plugin.listenbrainzfreshreleases');
my $prefs = preferences('plugin.listenbrainzfreshreleases');
my $cache = Slim::Utils::Cache->new();

# CF recommendations regenerate ~weekly; cache the resolved name-pool a day.
use constant RECS_TTL => 24 * 3600;

# How many artists to fan out across per radio refresh (the seed + similar), and
# how many top recordings to take from each — the candidate pool per top-up. A
# wide fan-out with few tracks each keeps the radio varied.
use constant ARTIST_FANOUT     => 24;
use constant PER_ARTIST_TRACKS => 8;
# Sample PER_ARTIST_TRACKS from this many of an artist's top recordings (random
# within the slice) so it's not always the same greatest hits.
use constant PER_ARTIST_POOL   => 40;

# Diversity controls: at most this many tracks from one artist per top-up, and
# don't reuse an artist until this many others have been served (a per-player
# FIFO cooldown), so successive top-ups rotate artists instead of repeating.
use constant MAX_PER_ARTIST => 1;
use constant ARTIST_COOLDOWN => 24;

# Last.fm similar-artist fallback (used when ListenBrainz has no similar artists
# for the seed AND the user has a Last.fm API key). Capped lower than ARTIST_FANOUT
# because Last.fm gives artist NAMES — each one without an inline MBID costs a
# MusicBrainz name->MBID lookup to become fannable.
use constant LFM_FANOUT => 12;

# Cap simultaneous MusicBrainz name->MBID lookups when resolving Last.fm artists.
# MusicBrainz's anonymous limit is ~1 req/s, so firing all LFM_FANOUT at once gets
# the bulk throttled (503) and silently dropped — defeating the fallback on a cold
# cache. A small bound drips them out; cached after the first run.
use constant MBID_RESOLVE_CONCURRENCY => 4;

# Library-FIRST resolution: if the user owns the track, play their copy (better
# quality, free, instant); otherwise stream it. The selection is already varied
# (similar-artist driven), so preferring owned copies is desirable here.
use constant LIB_MODE => 'first';

# Upper bound on the per-session no-repeat set (played track URLs). The set is
# never reset for the life of the session (that's the no-repeat guarantee), so
# cap it FIFO so a very long auto-DJ session can't grow it without limit — evicting
# the OLDEST url first means only tracks played thousands ago can recur.
use constant PLAYED_MAX => 5000;

my $API   = 'Plugins::ListenBrainzFreshReleases::API';
my $DSTMP = 'Slim::Plugin::DontStopTheMusic::Plugin';

# Per-client radio state: { served => { recording_mbid => 1 }, next_seed => mbid }.
# served keeps successive top-ups varied; next_seed lets the radio drift when the
# live queue offers no fresh MusicBrainz-tagged seed (e.g. our own streaming adds).
my %state;

# ---------------------------------------------------------------------------
# Register the two propagators with the core DSTM plugin (guarded so a disabled
# DSTM is a quiet no-op).
# ---------------------------------------------------------------------------
sub register {
    my ($class) = @_;

    eval { require Slim::Plugin::DontStopTheMusic::Plugin };
    unless ($DSTMP->can('registerHandler')) {
        $log->info("Don't Stop The Music not available; skipping propagator registration");
        return;
    }

    $DSTMP->registerHandler('PLUGIN_LBF_DSTM_RADIO',       \&radio);
    $DSTMP->registerHandler('PLUGIN_LBF_DSTM_RECOMMENDED', \&recommended);
    $log->info("Registered ListenBrainz DSTM propagators (Radio, Recommended)");
}

# ===========================================================================
# Mixer 1 — ListenBrainz Radio (seeded + evolving)
# ===========================================================================
sub radio {
    my ($client, $cb) = @_;
    unless ($client && length($prefs->get('username') // '')) {
        $cb->($client, []);
        return;
    }

    my $cid = $client->id;
    my ($seedMbid, $seedName) = _seedArtist($client);

    # Fallback used ONLY when the current track gives us no usable artist at all:
    # drift from the last batch's artist if we have one, else recommendations.
    # The current track must always take precedence over this (see below) so that
    # playing a brand-new album actually reseeds the radio.
    my $drift = sub {
        if (my $ns = $state{$cid}{next_seed}) {
            $log->info("DSTM radio: drifting from $ns");
            _radioFromArtist($client, $cb, $ns);
        }
        else {
            $log->info("DSTM radio: no seed, using recommendations");
            _recommendedFill($client, $cb);
        }
    };

    # 1. The current/last-played track has a MusicBrainz artist MBID → seed from it.
    if ($seedMbid) {
        _radioFromArtist($client, $cb, $seedMbid, $seedName);
        return;
    }

    # 2. It's a streaming track (no MBID) but we know its artist NAME → resolve the
    #    name to an MBID and seed from THAT. This MUST take precedence over the
    #    drift seed: otherwise playing a new streaming album never reseeds the radio
    #    — it'd keep following the leftover drift artist from a previous session
    #    (the "tracks didn't suit the seed" bug). Drift is only the fallback if the
    #    name can't be resolved.
    if (length($seedName // '')) {
        $log->info("DSTM radio: no seed MBID; resolving artist '$seedName'");
        $API->getArtistMbidByName($seedName,
            sub {
                my $mbid = shift;
                if ($mbid) { _radioFromArtist($client, $cb, $mbid, $seedName); }
                else {
                    $log->info("DSTM radio: '$seedName' unresolved; drift/recommendations");
                    $drift->();
                }
            },
            sub { $drift->() },
        );
        return;
    }

    # 3. No artist info on the current track at all → drift, else recommendations.
    $drift->();
}

# Run the similar-artists → top-recordings → resolve chain for a seed artist MBID.
# $seedName (when known) enables the Last.fm fallback if ListenBrainz has no
# similar artists for the seed.
sub _radioFromArtist {
    my ($client, $cb, $seed, $seedName) = @_;

    $log->info("DSTM radio: seed artist $seed" . (length($seedName // '') ? " ($seedName)" : ''));
    $API->getSimilarArtists($seed,
        sub {
            my $similar = shift // [];
            if (@$similar) {
                # The seed artist itself plus a weighted-random pick of similar
                # artists (higher score = likelier, but randomised so it evolves).
                my @artists = ($seed, _pickSimilar($similar, ARTIST_FANOUT - 1));
                _collectArtistTracks(\@artists, sub {
                    _resolveAndReturn($client, $cb, shift // [], 'radio');
                });
            }
            else {
                # ListenBrainz has no similar artists for this seed → try Last.fm
                # before giving up. Final fallback = the seed's own top recordings
                # (then DSTM's own random if even that's empty), as before.
                $log->info("DSTM radio: no LB similar artists for $seed");
                _radioViaLastfm($client, $cb, $seed, $seedName,
                    sub { _radioSeedOnly($client, $cb, $seed) });
            }
        },
        # LB request failed → try Last.fm too; final fallback = recommendations.
        sub {
            _radioViaLastfm($client, $cb, $seed, $seedName,
                sub { _recommendedFill($client, $cb) });
        },
    );
}

# Seed-only fan-out — the original empty-similar behaviour (just the seed artist's
# own top recordings). Empty pool → _resolveAndReturn returns [] → DSTM goes random.
sub _radioSeedOnly {
    my ($client, $cb, $seed) = @_;
    _collectArtistTracks([$seed], sub {
        _resolveAndReturn($client, $cb, shift // [], 'radio');
    });
}

# Last.fm similar-artist fallback for the radio. Needs the seed's NAME and a
# Last.fm key; resolves the returned artist names to MBIDs (bounded, parallel) and
# fans out from them plus the seed. No key / no name / nothing usable → $orig->().
sub _radioViaLastfm {
    my ($client, $cb, $seed, $seedName, $orig) = @_;

    unless (length($seedName // '') && length($prefs->get('lastfm_api_key') // '')) {
        $orig->();
        return;
    }

    $log->info("DSTM radio: trying Last.fm similar artists for '$seedName'");
    $API->getSimilarArtistsLastfm($seedName,
        sub {
            my $similar = shift // [];
            unless (@$similar) {
                $log->info("DSTM radio: Last.fm had no similar artists for '$seedName'");
                $orig->();
                return;
            }

            # Bias toward Last.fm's match score and cap the fan-out (each name
            # without an inline MBID costs a MusicBrainz lookup to resolve).
            my @ranked = sort { ($b->{score} // 0) <=> ($a->{score} // 0) } @$similar;
            @ranked = @ranked[0 .. LFM_FANOUT - 1] if @ranked > LFM_FANOUT;

            _resolveArtistMbids(\@ranked, sub {
                my $mbids = shift // [];
                unless (@$mbids) {
                    $log->info("DSTM radio: no Last.fm artists resolved to MBIDs");
                    $orig->();
                    return;
                }
                $log->info("DSTM radio: Last.fm gave " . scalar(@$mbids) . " artist MBID(s)");
                _collectArtistTracks([ $seed, @$mbids ], sub {
                    _resolveAndReturn($client, $cb, shift // [], 'radio');
                });
            });
        },
        sub { $orig->() },
    );
}

# Resolve Last.fm similar entries ({ name, artist_mbid }) to artist MBIDs: use the
# inline MBID when present, else a MusicBrainz name→MBID lookup (cached). The MB
# lookups are bounded to MBID_RESOLVE_CONCURRENCY at a time (MB rate limit) via a
# pump; $done gets a de-duplicated arrayref of MBIDs.
sub _resolveArtistMbids {
    my ($list, $done) = @_;
    my @list = @$list;
    unless (@list) { $done->([]); return; }

    my @mbids;
    my $total     = scalar @list;
    my $next      = 0;
    my $active    = 0;
    my $completed = 0;
    my $finished  = 0;

    my $finish = sub {
        return if $finished; $finished = 1;
        my %seen;
        $done->([ grep { length && !$seen{$_}++ } @mbids ]);
    };

    my $pump;
    $pump = sub {
        return if $finished;
        while ($active < MBID_RESOLVE_CONCURRENCY && $next < $total) {
            my $a = $list[$next++];
            $active++;
            my $one = sub {
                my $m = shift;
                push @mbids, lc $m if $m;
                $active--;
                $completed++;
                ($completed >= $total) ? $finish->() : $pump->();
            };
            # Inline MBID needs no lookup — complete it immediately (still counts
            # against $active so the loop accounts for it before resolving).
            if ($a->{artist_mbid}) { $one->($a->{artist_mbid}); }
            else {
                $API->getArtistMbidByName($a->{name}, $one, sub { $one->(undef) });
            }
        }
    };

    $pump->();
}

# Inspect the currently-playing track (scanning a few back if it has no usable
# metadata) and return (artist_mbid_or_undef, artist_name_or_undef). DSTM only
# fires when the queue is nearly empty, so the current track is effectively the
# tail — this both follows what you're hearing and evolves the queue forward, and
# it's more responsive than tail-seeding if you skip or drop on a new album. Uses
# DSTM's extractor: ($artist, $title, $duration, $id, $mbid, $artist_mbid, $extid).
sub _seedArtist {
    my ($client) = @_;
    return (undef, undef) unless $DSTMP->can('getMixablePropertiesFromTrack');

    my $pl = eval { Slim::Player::Playlist::playList($client) };
    return (undef, undef) unless ref $pl eq 'ARRAY' && @$pl;

    my $idx = eval { Slim::Player::Source::playingSongIndex($client) };
    $idx = $#$pl unless defined $idx && $idx >= 0 && $idx <= $#$pl;

    for my $i (reverse 0 .. $idx) {
        last if $idx - $i > 3;                       # only look back a few tracks
        my $track = $pl->[$i] or next;
        my @p = eval { $DSTMP->getMixablePropertiesFromTrack($client, $track) };
        my ($artist, $artist_mbid) = ($p[0], $p[5]);
        my $haveName = defined $artist && length $artist;
        next unless $haveName || $artist_mbid;       # skip un-usable entries

        # First (most-recent) track with usable info wins — return its MBID (if a
        # valid UUID) and/or its name.
        return (
            ($artist_mbid && $artist_mbid =~ /^[0-9a-f-]{36}$/i) ? lc $artist_mbid : undef,
            $haveName ? $artist : undef,
        );
    }
    return (undef, undef);
}

# Weighted-random pick of $n similar-artist MBIDs (score-biased, de-duplicated).
sub _pickSimilar {
    my ($similar, $n) = @_;
    return () unless ref $similar eq 'ARRAY' && @$similar;

    # Bias toward higher scores but keep randomness: take the top slice then shuffle.
    my @ranked = sort { ($b->{score} // 0) <=> ($a->{score} // 0) } @$similar;
    my $slice  = @ranked > ($n * 4) ? ($n * 4) : scalar @ranked;
    my @pool   = @ranked[0 .. $slice - 1];
    my @picked = (shuffle @pool)[0 .. ($n < @pool ? $n - 1 : $#pool)];
    return map { $_->{artist_mbid} } grep { $_->{artist_mbid} } @picked;
}

# Fan out top-recordings-for-artist across the chosen artists (bounded, parallel),
# merge into a candidate list of { recording_mbid, title, artist, artist_mbid }.
sub _collectArtistTracks {
    my ($artistMbids, $done) = @_;

    my @artists = grep { $_ } @$artistMbids;
    unless (@artists) { $done->([]); return; }

    my @cands;
    my $pending  = scalar @artists;
    my $finished = 0;
    my $finish = sub { return if $finished; $finished = 1; $done->(\@cands); };

    for my $ambid (@artists) {
        $API->getTopRecordingsForArtist($ambid,
            sub {
                my $recs = shift // [];
                # Sample from a deeper slice of the artist's catalogue (top
                # PER_ARTIST_POOL) rather than always the top PER_ARTIST_TRACKS, so
                # the radio plays album cuts too instead of the same greatest hits
                # every refresh.
                my $deep = @$recs > PER_ARTIST_POOL ? PER_ARTIST_POOL : scalar @$recs;
                my @pool = shuffle @{ $recs }[0 .. $deep - 1];
                my $take = @pool > PER_ARTIST_TRACKS ? PER_ARTIST_TRACKS : scalar @pool;
                for my $r (@pool[0 .. $take - 1]) {
                    next unless $r->{recording_mbid};
                    push @cands, { %$r, artist_mbid => $ambid };
                }
                $finish->() if --$pending <= 0;
            },
            sub { $finish->() if --$pending <= 0; },
        );
    }
}

# ===========================================================================
# Mixer 2 — ListenBrainz Recommended (personalised CF pool, shuffled)
# ===========================================================================
sub recommended {
    my ($client, $cb) = @_;
    unless ($client && length($prefs->get('username') // '')) {
        $cb->($client, []);
        return;
    }
    _recommendedFill($client, $cb);
}

# Build/return the CF recommendation name-pool, then resolve+return a batch.
sub _recommendedFill {
    my ($client, $cb) = @_;

    my $username = $prefs->get('username') // '';
    my $key = 'lbf:dstm:recs:' . $username;

    my $serve = sub {
        my $pool = shift // [];
        _resolveAndReturn($client, $cb, $pool, 'recommended');
    };

    if (my $cached = $cache->get($key)) {
        $serve->($cached);
        return;
    }

    $API->getRecommendations(
        count  => ($prefs->get('dstm_count') || 100),
        onDone => sub {
            my $ids = shift // [];
            unless (@$ids) { $cb->($client, []); return; }
            $API->getRecordingMetadata($ids, sub {
                my $meta = shift // {};
                my @pool;
                for my $mbid (@$ids) {
                    my $m = $meta->{$mbid} or next;
                    push @pool, { recording_mbid => $mbid, artist => $m->{artist}, title => $m->{title} };
                }
                # Only persist a NON-EMPTY pool. getRecordingMetadata is onDone-always
                # (best-effort — a transient metadata outage resolves onDone with {}),
                # so an empty @pool here can be a failure, not a genuine "no recs". Caching
                # it for RECS_TTL(1d) would pin DSTM to zero recommendations for a day (the
                # poisoned-cache class). Serve what we have; let an empty result retry.
                if (@pool) {
                    eval { $cache->set($key, \@pool, RECS_TTL); 1 }
                        or $log->warn("DSTM recs pool cache set failed: $@");
                }
                $log->info("DSTM recommended pool: " . scalar(@pool) . " of " . scalar(@$ids));
                $serve->(\@pool);
            });   # getRecordingMetadata is onDone-always (no onError arg)
        },
        onError => sub { $log->warn("DSTM recs fetch failed: " . (shift // '')); $cb->($client, []); },
    );
}

# ===========================================================================
# Shared: pick fresh candidates, resolve streaming-first, return a batch of URLs.
# ===========================================================================
sub _resolveAndReturn {
    my ($client, $cb, $cands, $which) = @_;
    $cands ||= [];

    unless (@$cands) {
        # A 'radio' pool comes back empty when the artist→tracks step yields nothing —
        # most importantly when ListenBrainz's Popularity API (top-recordings-for-artist)
        # is disabled server-side ("500 … currently disabled due to high load"). EVERY
        # radio sub-path (similar-artists, seed-only, AND the Last.fm fallback) funnels
        # through that one endpoint, so none of them can rescue this; without a net the
        # handler returns [] and core DSTM drops to random library tracks. Fall back ONCE
        # to the Recommended CF pool, which is a DIFFERENT endpoint (/1/cf/recommendation)
        # and stays up during a Popularity outage. 'recommended' never recurses here
        # (guarded by $which), so an all-endpoints-down case still terminates cleanly.
        if ($which eq 'radio') {
            $log->info("DSTM radio: empty candidate pool (Popularity API may be down); falling back to Recommended pool");
            _recommendedFill($client, $cb);
            return;
        }
        $log->info("DSTM $which: empty candidate pool");
        $cb->($client, []);
        return;
    }

    my $batch = $prefs->get('dstm_batch') || 15;   # match the init default in Plugin.pm
    my $tryN  = $batch * 3;   # over-fetch: not every candidate resolves to a playable track

    my $cid    = $client->id;
    my $seen    = $state{$cid}{served} ||= {};        # recording_mbids served (variety window)
    my $recent  = $state{$cid}{recent} ||= [];        # FIFO of recently-served artists
    my $played  = $state{$cid}{played} ||= {};        # track URLs EVER queued this session — never reset
    my $playedQ = $state{$cid}{played_order} ||= [];  # same urls in insertion order, for the FIFO cap

    # Hard no-repeat guard: never return a track URL we've already played this
    # session, nor anything already sitting in the play queue right now.
    my %blocked = %$played;
    my $plist = eval { Slim::Player::Playlist::playList($client) };
    if (ref $plist eq 'ARRAY') {
        for my $t (@$plist) {
            my $u = eval { (ref $t && $t->can('url')) ? $t->url : (!ref $t ? $t : undef) };
            $blocked{$u} = 1 if defined $u && !ref $u;
        }
    }

    my @candidates = _selectCandidates($cands, $seen, $recent, $tryN);
    if (!@candidates) {
        # Pool exhausted (everything served, or all artists on cooldown) → reset.
        %$seen = (); @$recent = ();
        @candidates = _selectCandidates($cands, $seen, $recent, $tryN);
    }

    # Mark attempted recordings + artists served (artists into the FIFO cooldown),
    # and remember an artist to drift toward next refresh.
    my %servedArtists;
    for my $c (@candidates) {
        $seen->{ $c->{recording_mbid} } = 1;
        my $a = _artistKey($c);
        $servedArtists{$a} = 1 if $a;
    }
    push @$recent, keys %servedArtists;
    splice(@$recent, 0, scalar(@$recent) - ARTIST_COOLDOWN) if @$recent > ARTIST_COOLDOWN;
    if ($which eq 'radio') {
        my @ambids = grep { $_ } map { $_->{artist_mbid} } @candidates;
        $state{$cid}{next_seed} = (shuffle @ambids)[0] if @ambids;
    }

    Plugins::ListenBrainzFreshReleases::Browse::_resolveTracks($client, \@candidates, sub {
        my $items = shift // [];
        my @urls;
        for my $it (@$items) {
            last if @urls >= $batch;
            my $u = $it->{url};
            next unless defined $u && !ref $u;
            next if $blocked{$u};        # already played this session or already queued
            $blocked{$u} = 1;            # de-dupe within this batch too
            $played->{$u} = 1;           # remember for the rest of the session
            push @$playedQ, $u;          # track insertion order for the FIFO cap
            push @urls, $u;
        }
        # Bound the never-reset played set FIFO — drop the oldest urls once over the
        # cap so a marathon session can't grow it without limit (an evicted url can
        # only recur after PLAYED_MAX others, so no practical repeat).
        while (@$playedQ > PLAYED_MAX) {
            my $old = shift @$playedQ;
            delete $played->{$old};
        }
        $log->info("DSTM $which: returning " . scalar(@urls) . " track(s) from "
            . scalar(@candidates) . " candidate(s)");
        $cb->($client, \@urls);
    }, LIB_MODE);
}

# Identity used for per-artist diversity: MBID where we have one (radio), else the
# normalised artist name (recommended pool carries no artist MBID).
sub _artistKey {
    my ($c) = @_;
    return $c->{artist_mbid} if $c->{artist_mbid};
    my $n = lc($c->{artist} // '');
    $n =~ s/^\s+|\s+$//g;
    return length $n ? "n:$n" : undef;
}

# Turn the raw candidate pool into a varied, ordered short-list: drop tracks whose
# recording was already served, prefer artists not on the cooldown FIFO, cap each
# artist to MAX_PER_ARTIST, then round-robin interleave across artists so the
# returned order alternates artists rather than clustering one.
sub _selectCandidates {
    my ($cands, $seen, $recent, $tryN) = @_;

    my %recentSet = map { $_ => 1 } @$recent;

    my %byArtist;
    for my $c (@$cands) {
        next if $seen->{ $c->{recording_mbid} };
        my $a = _artistKey($c) // $c->{recording_mbid};
        push @{ $byArtist{$a} }, $c;
    }
    return () unless %byArtist;

    # Prefer artists not used recently; only fall back to cooled-down ones if that
    # would leave too few artists to stay varied.
    my @artists = keys %byArtist;
    my @fresh   = grep { !$recentSet{$_} } @artists;
    @artists = @fresh if @fresh >= 3;

    # Cap per artist (shuffled within), then shuffle artist order.
    my %queue;
    for my $a (@artists) {
        my @t   = shuffle @{ $byArtist{$a} };
        my $cap = $#t < (MAX_PER_ARTIST - 1) ? $#t : (MAX_PER_ARTIST - 1);
        $queue{$a} = [ @t[0 .. $cap] ];
    }
    my @order = shuffle @artists;

    my @out;
    my $added = 1;
    while ($added && @out < $tryN) {
        $added = 0;
        for my $a (@order) {
            next unless @{ $queue{$a} };
            push @out, shift @{ $queue{$a} };
            $added = 1;
            last if @out >= $tryN;
        }
    }
    return @out;
}

1;
