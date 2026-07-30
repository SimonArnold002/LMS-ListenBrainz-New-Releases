#!/usr/bin/env perl
# Verify the favurl LBF hands Listen Later, using the REAL subs from both plugins:
# LBF's _attachFavUrl / _llRelType and LL's relTypeFor / _normRelType / singleIsWrong.
# No stubs, no paraphrase — the sources are read and eval'd, so this fails the moment
# either end changes shape.
#
# ONE private param carries release information: '&rt=', the MusicBrainz release-group
# primary type (0.9.141). It is not sufficient on its own — MusicBrainz types a release
# group Single however many B-sides it carries, while LL's 'single' means "exactly ONE
# track" and marks the release heard as soon as that track ends (LL 0.1.88). LL closes
# that itself by resolving the release and counting what's playable; LBF does not send a
# count.
#
# A SECOND private param carries the release NAME: '&al=', the clean album title (0.9.144).
# Material substitutes $ALBUMNAME/$TITLE with an online row's DISPLAY LABEL verbatim, and
# these rows are labelled by each streaming plugin's own renderer — Bandcamp's read
# "Title (Album)" — so without this LL stores the label, which is both what it shows AND
# the second segment of its artist|album|year dedupe key. Section 3 drives LL's REAL
# _stripPrivateParams over what _attachFavUrl actually emitted, so neither end can drift.
#
# There is deliberately NO '&tc=' count param. 0.9.142 added one, 0.9.143 removed it:
# those fields live on each service's per-ALBUM endpoint and are absent from the SEARCH
# responses matches come from, so nothing was ever sent — verified live on all three
# services. The check below ASSERTS no count param is emitted, so re-adding one without
# a real end-to-end observation fails this test. (The 0.9.142 tests all passed while the
# feature was inert, because each supplied the field itself.)
use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

# Overridable so the suite can be pointed at a throwaway copy and ANTI-TESTED — i.e. run
# against code with the fix removed, to prove it actually catches the bug it claims to.
# A test that has never failed on purpose has not been shown to test anything:
#     LBF_BROWSE=/tmp/old/Browse.pm perl tools/t_ll_handshake.pl   # must exit non-zero
my $LBF = $ENV{LBF_BROWSE} || '/Users/simona/Documents/GitHub/LMS-ListenBrainz-New-Releases/ListenBrainzFreshReleases/Browse.pm';
my $LL  = $ENV{LL_SOURCES} || '/Users/simona/Documents/GitHub/LMS-Listen-to-Later/ListenLater/Sources.pm';
my $LLP = $ENV{LL_PLUGIN}  || '/Users/simona/Documents/GitHub/LMS-Listen-to-Later/ListenLater/Plugin.pm';

sub grab {
    my ($file, $name) = @_;
    open(my $fh,'<:encoding(UTF-8)',$file) or die "$file: $!";
    my $src = do { local $/; <$fh> }; close $fh;
    $src =~ /^sub \Q$name\E\b\s*\{/mg or die "no sub $name in $file";
    my $s = $-[0]; my $i = pos($src); my $d = 1;
    while ($i < length($src) && $d) { my $c = substr($src,$i++,1); $d++ if $c eq '{'; $d-- if $c eq '}' }
    return substr($src,$s,$i-$s) . "\n";
}

eval "package LBF; use strict; use warnings;\n"
   . grab($LBF,'_attachFavUrl') . grab($LBF,'_llRelType') . "1;" or die $@;
eval "package LL; use strict; use warnings;\n"
   . grab($LL,'relTypeFor') . grab($LL,'_normRelType') . grab($LL,'singleIsWrong') . "1;" or die $@;

# LL's RECEIVING end, verbatim from its Plugin.pm. This is the sub that strips every
# private param off the favurl in place and hands back what it found — so section 3 is a
# genuine round trip, not a paraphrase of one. It stands alone (its only dependency is
# URI::Escape), which is exactly why LL 0.1.89 lifted it out of _addCtxCommand.
eval "package LLP; use strict; use warnings;\n" . grab($LLP,'_stripPrivateParams') . "1;" or die $@;

my $bad = 0;

# ---------------------------------------------------------------------------
# 1. The wire: what _attachFavUrl actually emits, and what LL makes of it.
# ---------------------------------------------------------------------------
# LL's receiving end, mirroring _addCtxCommand: strip the private param, then classify.
# At add time LL has no count of its own (that arrives from its background resolve), so
# the type it stores AT INSERT is whatever rt= alone yields.
sub ll_receive {
    my ($fav) = @_;
    my $rt = ($fav =~ s{[?&]rt=([^&]*)}{}) ? $1 : undef;
    return (LL::relTypeFor(service => $rt), $rt, $fav);
}

print "1. The '&rt=' handshake on the wire\n";
printf "%-11s %-10s %-10s %s\n", 'MB type', 'sends rt=', 'LL stores', 'note';
printf "%s\n", '-' x 78;

for my $mbType ('Album', 'EP', 'Single', 'Broadcast', 'Other', '') {
    my $rt = LBF::_llRelType($mbType);
    my $it = { _albumid => '12345' };
    LBF::_attachFavUrl($it, 'Qobuz', 'https://art/x.jpg', 'Jack White', '2026', $rt);
    my $fav = $it->{favorites_url};

    my ($stored, $gotRt, $residue) = ll_receive($fav);

    my @errs;
    # No count param, ever — see the header. Guards against re-adding it unverified.
    push @errs, "EMITS A COUNT PARAM: $fav" if $fav =~ /[?&]tc=/;
    # rt= must not survive the strip: one left behind travels on into LL's source and
    # album-id parsing, and into the stored record.
    push @errs, "LEFTOVER '$residue'"
        if $residue =~ /[?&]rt=/ || $residue !~ m{^qobuz://album:12345};
    # An unmappable MB type must send nothing rather than assert a wrong one.
    push @errs, "asserted a type for '$mbType'"
        if !grep { $_ eq lc $mbType } qw(album ep single) and defined $gotRt;
    $bad += scalar @errs;

    printf "%-11s %-10s %-10s %s%s\n", ($mbType || '(blank)'), ($rt // '(omitted)'),
        ($stored // 'undef'),
        (defined $gotRt ? 'type asserted' : 'left to LL to work out'),
        (@errs ? '  <-- ' . join('; ', @errs) : '');
}

# ---------------------------------------------------------------------------
# 2. LL's decision, once its OWN resolve supplies a count.
# ---------------------------------------------------------------------------
# This is where the 0.1.88 fix lives. The count never comes off the wire — it comes from
# LL resolving the release (Sources::classifyRelType) — so these cases cover the type it
# ends up with after that check.
print "\n2. LL's classification once it has resolved a count\n";
printf "%-11s %-7s %-8s %s\n", 'asserted', 'tracks', 'LL says', 'why it matters';
printf "%s\n", '-' x 96;

my @CASES = (
    ['album',   12, 'album',  'ordinary album'                                        ],
    ['album',    1, 'album',  'ONE-track album: label kept, but the total is now known'],
    ['ep',       5, 'ep',     'ordinary EP'                                           ],
    ['ep',       1, 'ep',     'one-track EP: label kept, total known'                 ],
    ['single',   1, 'single', 'a real single'                                         ],
    ['single',   3, 'ep',     'MB Single with B-sides — must NOT stay a single'        ],
    ['single',   9, 'album',  'MB Single, 9 tracks — album, not EP (the EP floor is 2)'],
    [undef,      4, 'ep',     'nothing asserted: the count classifies'                ],
    [undef,     12, 'album',  'nothing asserted: the count classifies'                ],
    [undef,      1, 'single', 'nothing asserted: one track is a single'                ],
    ['single', undef, 'single', 'resolve failed: the claim stands (LL 0.1.90 retries)' ],
    ['album',  undef, 'album',  'resolve failed: the claim stands'                     ],
    [undef,    undef, undef,    'nothing known: LL leaves it unclassified'             ],
);

for my $c (@CASES) {
    my ($asserted, $tracks, $expect, $why) = @$c;
    my $got = LL::relTypeFor(service => $asserted,
                             (defined $tracks ? (count => $tracks) : ()));
    my $ok = (!defined $got && !defined $expect)
          || (defined $got && defined $expect && $got eq $expect);
    $bad++ unless $ok;
    printf "%-11s %-7s %-8s %s%s\n", ($asserted // '(none)'),
        (defined $tracks ? $tracks : '(none)'), ($got // 'undef'), $why,
        ($ok ? '' : '  <-- WRONG, expected ' . ($expect // 'undef'));
}

print "\nThe 3-track release MusicBrainz calls a Single, by what is known:\n";
printf "  rt= alone, at insert     -> '%s'  (0.9.141 shipped this: Played after ONE of 3 tracks)\n",
    LL::relTypeFor(service => 'single') // 'undef';
printf "  after LL's own resolve   -> '%s'      (0.1.88: a real listen needed, total known = 3)\n",
    LL::relTypeFor(service => 'single', count => 3) // 'undef';
printf "  no type at all, 3 tracks -> '%s'      (the count alone was always right here)\n",
    LL::relTypeFor(count => 3) // 'undef';

# ---------------------------------------------------------------------------
# 3. '&al=' — the album TITLE on the wire, round-tripped through LL's REAL receiver.
# ---------------------------------------------------------------------------
# WHY THIS SECTION EXISTS. Material gives a plugin no structured album name for an online
# row: it substitutes $ALBUMNAME/$TITLE with the row's DISPLAY LABEL, and these rows are
# labelled by each streaming plugin's own renderer, qualifier and all.
#
# BE PRECISE ABOUT WHAT THIS PARAM BUYS — it is NOT "Bandcamp's (Album) suffix". LL has
# stripped a trailing "(Album)"/"(Track)"/"(Hi-Res …)"/"(Explicit)"/"(Mono)"/"(Stereo)" and a
# trailing "(YYYY)" since its 0.1.35, and does so whether or not '&al=' arrives — the cases
# below prove that by passing on both sides of the anti-test. What '&al=' replaces is the
# BLOCKLIST ITSELF: any qualifier not on that fixed list ("(Deluxe Edition)", "(Bonus Track
# Version)", "(Remastered)") still reaches the stored title today, and with it the second
# segment of LL's artist|album|year dedupe key. Sending the MusicBrainz release name we
# already hold makes the title authoritative instead of a guess at what to strip.
#
# CONSEQUENCE, deliberate: an edition qualifier that is genuinely part of the SERVICE's album
# title is replaced by MB's plain release name, so a deluxe edition and the standard one now
# key alike and dedupe together. That is the right call here — LBF matched both to the SAME
# MusicBrainz release — but it is a behaviour change, not a pure cleanup.
#
# Everything below asserts on what LL's OWN _stripPrivateParams returns from the string
# _attachFavUrl actually built. Both halves are read from live source, so a change to either
# repo fails here.
print "\n3. The '&al=' album-title handshake (LBF emits -> LL's real receiver strips)\n";
printf "%-34s %-30s %s\n", 'service title (what we send)', 'row label Material would send', 'LL stores';
printf "%s\n", '-' x 96;

# What LL's caller does with what it stripped (ListenLater/Plugin.pm, _addCtxCommand):
#     my $album = (defined $favAlbum && length $favAlbum) ? $favAlbum : $p{name};
#     $album =~ s/\s*\((\d{4})\)\s*$//;
#     $album =~ s/\s*\((?:Hi-Res[^)]*|Explicit|Mono|Stereo|Album|Track)\)\s*$//i;
# i.e. '&al=' WINS over the row label, and its absence falls back to the label PUT THROUGH
# LL's own cleanup. Mirrored in full here — modelling only the first line would overstate
# what this param buys, because that blocklist ALREADY handles a trailing "(Album)" and a
# trailing "(YYYY)". LL's own tools/t_addpath.pl drives the real statements end to end.
sub ll_stores {
    my ($got, $rowLabel) = @_;
    my $album = (defined $got->{album} && length $got->{album}) ? $got->{album} : $rowLabel;
    $album = as_chars($album);
    $album =~ s/\s*\((\d{4})\)\s*$//;
    $album =~ s/\s*\((?:Hi-Res[^)]*|Explicit|Mono|Stereo|Album|Track)\)\s*$//i;
    return $album;
}

# ENCODING CONTRACT — verified, not assumed. LBF escapes with uri_escape_utf8 (character
# string in, %XX of the UTF-8 bytes out) and LL unescapes with uri_unescape, which returns
# OCTETS, never a utf8-flagged string. So a non-ASCII title reaches LL as bytes.
#
# That is not a defect and must not be "fixed" on either side: it is exactly what the '&a='
# artist param has done since 0.9.58, it is what everything downstream of Material already
# handles (the whole request arrives as UTF-8 octets), and LL stores and re-emits the same
# bytes — so the round trip is lossless and consistent. '&al=' inherits it deliberately.
#
# The comparisons below therefore decode before comparing, AND assert the value really is
# octets — so if either end ever starts handing back characters, this fails rather than
# silently changing what lands in LL's dedupe key.
sub as_chars { my ($s) = @_; return $s unless defined $s; utf8::decode($s); return $s }
sub is_octets { my ($s) = @_; return !defined($s) || !utf8::is_utf8($s) }

# svc, cover-or-bandcamp-blob, artist, year, MB album title, row label, what LL must store
my @AL = (
    ['Qobuz',    'https://art/x.jpg', 'Cola',        '2026',
     'Cost Of Living Adjustment', 'Cost Of Living Adjustment', 'Cost Of Living Adjustment',
     'ordinary case: label already clean'],
    ['Bandcamp', undef,              'Fruit Bats',  '2026',
     'The Landfill', 'The Landfill (Album)', 'The Landfill',
     "Bandcamp's type suffix — LL's blocklist ALREADY handles this one"],
    ['Bandcamp', undef,              'Walrus Ghost','2026',
     'If You Could Be Here Now', 'If You Could Be Here Now (Deluxe Edition)', 'If You Could Be Here Now',
     'THE REAL GAIN: not on the blocklist, so only al= cleans it'],
    ['Qobuz',    'https://art/r.jpg', 'Bright Eyes', '2005',
     'Digital Ash in a Digital Urn', 'Digital Ash in a Digital Urn (Remastered)',
     'Digital Ash in a Digital Urn',
     'ditto — and note the edition now keys with the standard one'],
    ['Tidal',    'https://art/y.jpg', 'Sigur Rós',   '2002',
     '( )', '( ) (Remastered)', '( )',
     'punctuation-only title survives escaping'],
    ['Qobuz',    'https://art/z.jpg', 'Someone',     '2026',
     'Q&A = Answers?', 'Q&A = Answers? (Deluxe)', 'Q&A = Answers?',
     'delimiters in the title must not forge params'],
    ['Qobuz',    'https://art/w.jpg', '踊ってばかりの国', '2019',
     '光の中に', '光の中に (Album)', '光の中に',
     'wide characters round-trip intact'],
    ['Qobuz',    'https://art/v.jpg', 'Nobody',      '2026',
     '', 'Whatever The Row Says', 'Whatever The Row Says',
     'no album to send: LL falls back to the label, as before'],
);

for my $c (@AL) {
    my ($svc, $art, $artist, $year, $album, $rowLabel, $want, $why) = @$c;

    my $it = { _albumid => '12345' };
    # Bandcamp is the ONE service whose favurl packs its cover+page url into '?b=' — and it
    # is also the service with the polluted labels, so it must be exercised in that shape.
    $it->{_albumurl} = 'https://fruitbats.bandcamp.com/album/the-landfill' if $svc eq 'Bandcamp';
    LBF::_attachFavUrl($it, $svc, $art, $artist, $year, 'album', $album);
    my $fav = $it->{favorites_url};

    my $p = { favurl => $fav };
    my $got = LLP::_stripPrivateParams($p);
    my $stored = as_chars(ll_stores($got, $rowLabel));

    my @errs;
    push @errs, "stored '$stored'" if $stored ne $want;
    # See the encoding contract above: a stripped value must arrive as octets, like '&a='.
    push @errs, 'album came back utf8-flagged, not octets' unless is_octets($got->{album});
    push @errs, 'artist came back utf8-flagged, not octets' unless is_octets($got->{artist});
    # A title we HAVE must actually be emitted — otherwise deleting the feature would leave
    # every case above passing through the fallback and look green.
    push @errs, 'no al= emitted' if length $album && $fav !~ /[?&]al=/;
    push @errs, 'al= emitted for an empty title' if !length $album && $fav =~ /[?&]al=/;
    # '&a=' must not eat '&al=' (it needs '=' straight after the 'a'), and vice versa.
    push @errs, "artist lost (got " . (as_chars($got->{artist}) // 'undef') . ")"
        if (as_chars($got->{artist}) // '') ne $artist;
    # Everything else on the wire still has to survive alongside it.
    push @errs, 'year lost'     if ($got->{year}     // '') ne $year;
    push @errs, 'rel_type lost' if ($got->{rel_type} // '') ne 'album';
    push @errs, 'cover lost'    if defined $art && ($got->{cover} // '') ne $art;
    push @errs, 'bandcamp url lost'
        if $svc eq 'Bandcamp' && ($got->{bandcamp_url} // '') !~ m{bandcamp\.com};
    # And the residue must be the bare album ref LL's source/album-id parsing expects —
    # no leftover param, no stray delimiter left glued on the end.
    push @errs, "residue '$p->{favurl}'" if $p->{favurl} ne lc($svc) . '://album:12345';
    $bad += scalar @errs;

    printf "%-34s %-30s %-26s %s%s\n", ($album || '(none)'), $rowLabel, $stored, $why,
        (@errs ? '  <-- ' . join('; ', @errs) : '');
}

# The param can arrive FIRST (a release with no art, no artist, no year, no type), which
# means LL strips "?al=..." and leaves the remaining params starting with '&'. Each strip
# takes its own leading delimiter, so the url still ends up bare — pinned here because a
# regex that consumed a trailing '&' instead would silently corrupt this case only.
{
    my $it = { _albumid => 'abc' };
    LBF::_attachFavUrl($it, 'Qobuz', undef, undef, undef, undef, 'Lone Param');
    my $p = { favurl => $it->{favorites_url} };
    my $got = LLP::_stripPrivateParams($p);
    my @errs;
    push @errs, "emitted '$it->{favorites_url}'" if $it->{favorites_url} !~ m{^qobuz://album:abc\?al=};
    push @errs, "album '" . ($got->{album} // 'undef') . "'" if ($got->{album} // '') ne 'Lone Param';
    push @errs, "residue '$p->{favurl}'"         if $p->{favurl} ne 'qobuz://album:abc';
    $bad += scalar @errs;
    printf "\n  al= as the ONLY param -> clean album ref%s\n",
        (@errs ? '  <-- ' . join('; ', @errs) : '  ok');
}

# ---------------------------------------------------------------------------
# 4. THE CALL SITES: '&al=' must carry the SERVICE's title, never MusicBrainz's.
# ---------------------------------------------------------------------------
# Everything above drives _attachFavUrl with an album passed in by the test, so it proves the
# param is BUILT and PARSED correctly and cannot say a word about WHICH NAME the plugin
# chooses to hand it — which is where the real bug lived: 0.9.144 first shipped passing
# $album, the MusicBrainz/ListenBrainz release name, and every assertion above still passed.
#
# Why the service's name is the only correct one: by the time a favurl exists we have
# RESOLVED the release to a specific service album, and LL's Played auto-detection matches
# the PLAYING track's album title (which the service reports) while its dedupe key must agree
# with a direct add from that same service. MB and the services disagree constantly —
# ListenBrainz has aksfx "Radio: Fourth Space (Original Music from Big Walk)" where Qobuz has
# "…(Original Music from the Game \"Big Walk\")" — so sending MB's name silently stops
# releases ever reaching Played.
#
# Asserted against the SOURCE, because the choice is made at the call site and there is no
# return value to inspect. Crude, but it fails loudly the moment someone passes the MB name
# again, which no behavioural test here can do.
print "\n4. The call sites send the SERVICE's title, not MusicBrainz's\n";
printf "%s\n", '-' x 78;
{
    open(my $fh, '<', $LBF) or die "can't read $LBF: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    # Every _attachFavUrl(...) call in the plugin, with its argument list flattened.
    my @calls;
    while ($src =~ /_attachFavUrl\(\s*(.*?)\)\s*;/gs) {
        my $args = $1;
        $args =~ s/\s*#[^\n]*//g;   # strip trailing comments inside the arg list
        $args =~ s/\s+/ /g;
        push @calls, $args;
    }

    printf "  found %d call site(s)\n", scalar @calls;
    $bad++ unless @calls == 2;   # _findPlayable settle loop + the manual Bandcamp pin
    print "  <-- expected 2 call sites, the settle loop and the Bandcamp pin\n"
        unless @calls == 2;

    for my $args (@calls) {
        # The 7th argument is the album name. Anything mentioning a bare $album is the bug.
        my ($last) = $args =~ /,\s*([^,]+)\s*$/;
        $last //= '';
        # ONLY `_svctitle` is acceptable — the raw service album title stashed at match
        # time. The two ways to get this wrong have BOTH now shipped, so both are named:
        #   $album            -> the MusicBrainz/ListenBrainz release name (0.9.144)
        #   {name} / {line1}  -> the plugin's rendered ROW LABEL, artist baked in (0.9.145;
        #                        Qobuz renders it artist-first, Bandcamp artist-last, so it
        #                        broke Played on every service and polluted the dedupe key)
        my $ok    = $last =~ /\{\s*_svctitle\s*\}/;
        my $mb    = $last =~ /\$album\b/;
        my $label = $last =~ /\{\s*(?:name|line1)\s*\}/;
        $bad++ if !$ok || $mb || $label;
        printf "  %-46s %s\n", $last,
            ($mb    ? '<-- SENDS THE MUSICBRAINZ NAME'
           : $label ? '<-- SENDS THE RENDERED ROW LABEL (artist baked in)'
           : !$ok   ? '<-- not the stashed service title'
           :          'ok (service title)');
    }
}

print $bad ? "\n$bad case(s) WRONG\n" : "\nall cases correct\n";
exit($bad ? 1 : 0);
