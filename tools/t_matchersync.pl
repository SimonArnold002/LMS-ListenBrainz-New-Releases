#!/usr/bin/env perl
# FLEET MATCHER SYNC — the three Discography-origin rules ported into LBF (0.9.194).
#
# WHY THIS EXISTS. `_norm`/`%FOLD`/`_albumMatches` are ONE engine copied into five repos, and
# they had drifted for weeks with Discography ahead: DSC proved three rules in the field and
# held them DSC-only until they were worth porting. This suite is the gate for that port, so
# each rule is pinned by the failure that MOTIVATED it rather than by a tidy synthetic case.
#
# The three, and the field failure each one closes:
#   1. APOSTROPHES ELIDE (DSC 0.44.26). Spacing the mark keyed "Jane's Addiction" as
#      'jane s addiction' against 'janes addiction'. `_artistMatch` is an exact-token SUBSET
#      test and the artist gate is MANDATORY, so the act matched NOTHING from any source.
#   2. %FOLD 10 -> ~90 entries (DSC 0.44.26). Extended-Latin/IPA letters survived NFD as
#      themselves, so a stylised name keyed differently from its plain spelling.
#   3. COMPOUND-WORD collapse in `_albumMatches` (DSC 0.50.6). The Rolling Stones' 1964 debut
#      is "England's Newest Hit Makers" on MusicBrainz and "…Hitmakers" on the services; no
#      tier treated a space as optional, so the tile was hidden.
#
# THE REGRESSION HALF MATTERS AS MUCH AS THE PORT. Rule 1 lands right next to the "!" fold
# (PFR 0.7.8), which has its own all-marks fallback so "!!!" does not normalise to empty and
# get rejected by that same mandatory artist gate — the apostrophe rule must not disturb it.
# And rule 3 is EXACT collapsed equality, never a prefix: collapsing spaces destroys the word
# boundary the prefix tiers rely on, so a prefix rule here would let "hitmakers…" swallow an
# unrelated title. Both are asserted below as NEGATIVES.
#
# Uses the REAL subs AND the REAL %FOLD grabbed from Browse.pm — no stubbed copies, so a
# change to either fails here rather than passing against a stale duplicate.
#
# PORTED VERBATIM FROM PFR's copy (0.9.33) — same assertions, same order, only the module
# path and the env override changed, plus an LBF-ONLY section 4. Keeping the shared body
# identical is deliberate: the two files should stay diffable, so a future rule added in one
# repo is visibly missing from the other.
#
# Run from the repo root:  perl tools/t_matchersync.pl
use strict; use warnings; use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

my $LBF = $ENV{LBF_BROWSE} || 'ListenBrainzFreshReleases/Browse.pm';
sub slurp { open(my $fh,'<:encoding(UTF-8)',$_[0]) or die "$_[0]: $!"; local $/; <$fh> }
my $SRC = slurp($LBF);

sub grab { my ($n)=@_; $SRC =~ /\nsub \Q$n\E \{.*?\n\}\n/s or die "no sub $n"; return $& }
# %FOLD is GRABBED, not retyped. A hand-copied table is exactly the drift this suite exists
# to catch, and it would silently pass while the shipped fold changed underneath it.
sub grabFold { $SRC =~ /\nmy %FOLD = \(.*?\n\);\n/s or die "no %FOLD"; return $& }

eval "package X; use strict; use warnings; use utf8;\n"
   . 'my $HAVE_NFD = eval { require Unicode::Normalize; 1 } ? 1 : 0;' . "\n"
   . grabFold()
   . join('', map { grab($_) } qw(_norm _asciiNorm _punctNorm _stripFmt
                                  _stripArtistPrefix _artistMatch _albumMatches
                                  _trackMatches))
   . "1;" or die $@;

my ($p,$f)=(0,0);
sub is { my($d,$g,$w)=@_; my $ok=((defined $g?$g:'') eq (defined $w?$w:'')); $ok?$p++:$f++;
    printf "%s %-44s got=%-32s want=%s\n",($ok?'ok  ':'FAIL'),$d,"'".(defined $g?$g:'')."'","'".(defined $w?$w:'')."'"; }
# NOT `ok($x =~ /re/, ...)` — a failed match returns the EMPTY LIST, which in list context
# makes the call short one argument and the description lands in the condition slot, so the
# assertion passes while testing nothing. Scalarised on the way in.
sub ok { my($d,$c)=@_; my $b = $c ? 1 : 0; $b?$p++:$f++; printf "%s %s\n",($b?'ok  ':'FAIL'),$d }

# FIXTURES ARE UPGRADED, and this is a real trap rather than ceremony. Perl only sets the
# UTF8 flag on a literal once it carries a codepoint ABOVE U+00FF, so "\x{f0}ark" is stored
# as unflagged latin-1 while "\x{283}ine" is flagged. `_norm` folds only inside
# `if ($HAVE_NFD && utf8::is_utf8($s))`, so an unflagged fixture silently SKIPS the fold and
# the assertion fails against perfectly good code — which is exactly what happened first time
# round here, and it failed only for the sub-256 entries (\x{f0}, \x{e6}, \x{f3}). Live input
# is decoded from the services' JSON and always arrives flagged, so upgrading reproduces
# production rather than papering over it. See the fleet's chars-vs-octets note.
sub n_ { my $s = shift; utf8::upgrade($s); return X::_norm($s) }

# _albumMatches($artistNorm, $albumNorm, $candArtist, $candTitle, $albumRaw)
# _trackMatches($artistNorm, $titleNorm, $candArtist, $candTitle) — LBF only
sub m_ { my ($artist,$album,$candArtist,$candTitle)=@_;
    return X::_albumMatches(n_($artist), n_($album), $candArtist, $candTitle, $album) }

print "== 1. APOSTROPHES ELIDE, they do not become a space (DSC 0.44.26)\n";
is('straight apostrophe',      n_("Jane's Addiction"),        'janes addiction');
is('no apostrophe agrees',     n_("Janes Addiction"),         'janes addiction');
is('curly U+2019 agrees',      n_("Jane\x{2019}s Addiction"), 'janes addiction');
is('modifier U+02BC agrees',   n_("Jane\x{02bc}s Addiction"), 'janes addiction');
is("O'Connor",                 n_("Sin\x{e9}ad O'Connor"),    'sinead oconnor');
is("D'Angelo",                 n_("D'Angelo"),                'dangelo');
is("The B-52's",               n_("The B-52's"),              'the b 52s');
is("The B-52s agrees",         n_("The B-52s"),               'the b 52s');

print "\n== 1b. THE \"'n'\" GUARD — it joins two WORDS, so it spaces instead of eliding\n";
is("Rock'n'Roll",              n_("Rock'n'Roll"),             'rock n roll');
is("Rock 'n' Roll agrees",     n_("Rock 'n' Roll"),           'rock n roll');
is("Rock N Roll agrees",       n_("Rock N Roll"),             'rock n roll');
is("curly 'n' agrees",         n_("Rock\x{2019}n\x{2019}Roll"),'rock n roll');
is('elide would give rocknroll', (n_("Rock'n'Roll") eq 'rocknroll' ? 'BROKEN':'ok'), 'ok');

print "\n== 1c. REGRESSION: the \"!\" fold (0.7.8) still stands beside the new rule\n";
is('P!nk interior mark is a letter', n_('P!nk'),              'pink');
is('Panic! is punctuation',    n_('Panic! At The Disco'),     'panic at the disco');
is('Panic (no !) agrees',      n_('Panic At The Disco'),      'panic at the disco');
is('Wham!',                    n_('Wham!'),                   'wham');
is('!!! keeps the old fold',   n_('!!!'),                     'iii');
ok('!!! never normalises to empty (artist gate rejects an empty side)',
   length(n_('!!!')) > 0);
is('Ke$ha',                    n_('Ke$ha'),                   'kesha');
is('Layo & Bushwacka!',        n_('Layo & Bushwacka!'),       'layo and bushwacka');

print "\n== 2. %FOLD — the entries the 10-entry table did NOT carry (DSC 0.44.26)\n";
is("ligature \x{133} -> ij",   n_("\x{133}sselmeer"),         'ijsselmeer');
is("digraph \x{1c6} -> dz",    n_("\x{1c6}ungla"),            'dzungla');
is("barred \x{167} -> t",      n_("\x{167}ree"),              'tree');
is("hooked \x{192} -> f",      n_("\x{192}unk"),              'funk');
is("IPA \x{283} -> sh",        n_("\x{283}ine"),              'shine');
is("schwa \x{259} -> e",       n_("\x{259}cho"),              'echo');
is("turned \x{250} -> a",      n_("\x{250}pple"),             'apple');
is("long s \x{17f} -> s",      n_("\x{17f}ong"),              'song');
is("kept: \x{f0} -> d",        n_("\x{f0}ark"),               'dark');
is("kept: \x{e6} -> ae",       n_("\x{e6}ther"),              'aether');
is('plain diacritic still NFD-stripped', n_("Sigur R\x{f3}s"), 'sigur ros');

print "\n== 3. COMPOUND-WORD collapse in _albumMatches (DSC 0.50.6)\n";
my $STONES = 'The Rolling Stones';
ok('field case: MB "Hit Makers" vs service "Hitmakers"',
   m_($STONES, "England's Newest Hit Makers", $STONES, "England's Newest Hitmakers"));
ok('symmetric: MB one word vs service two words',
   m_($STONES, "England's Newest Hitmakers", $STONES, "England's Newest Hit Makers"));
ok('the exact two-word spelling still matches',
   m_($STONES, "England's Newest Hit Makers", $STONES, "England's Newest Hit Makers"));
ok('curly apostrophe on the service side',
   m_($STONES, "England's Newest Hit Makers", $STONES, "England\x{2019}s Newest Hitmakers"));

print "\n== 3b. …and what it must NOT do\n";
ok('EXACT, not a prefix: "Hitmakers Live" is not swallowed',
   !m_($STONES, "England's Newest Hit Makers", $STONES, "England's Newest Hitmakers Live"));
ok('the mandatory artist gate still applies',
   !m_($STONES, "England's Newest Hit Makers", 'The Beatles', "England's Newest Hitmakers"));
ok('a <6-char collapsed key does NOT collide',
   !m_('Some Band', 'Go Go', 'Some Band', 'GoGo'));
ok('an unrelated title still does not match',
   !m_($STONES, "England's Newest Hit Makers", $STONES, 'Aftermath'));
ok('collapse does not fuse two genuinely different albums',
   !m_($STONES, 'Let It Bleed', $STONES, 'Letit Bleedx'));

print "\n== 4. LBF ONLY: the rules reach the TRACK path too (_trackMatches)\n";
# THE POINT OF THIS SECTION. `_trackMatches` is LBF's alone — no other repo has it, so the
# fleet check cannot say a word about it and PFR's copy of this suite never exercises it. It
# shares `_norm` and `_artistMatch` with the album path, so rules 1 and 2 reach the
# Created-for-You playlists, the follow feed and the DSTM mixers by construction; asserted
# here because "by construction" is what stopped being true the last three times this engine
# drifted. NOTE it deliberately has NO compound-word tier: that rule is album-only in every
# repo, and track titles are short enough that a >=6-char collapsed key would be far likelier
# to collide.
sub t_ { my ($artist,$title,$candArtist,$candTitle)=@_;
    return X::_trackMatches(n_($artist), n_($title), $candArtist, $candTitle) }

ok('apostrophe rule reaches tracks: elided vs spelled',
   t_("Jane's Addiction", "Been Caught Stealin'", "Janes Addiction", 'Been Caught Stealin'));
ok('curly apostrophe on the service side of a TRACK artist',
   t_("Jane's Addiction", 'Jane Says', "Jane\x{2019}s Addiction", 'Jane Says'));
ok('%FOLD reaches tracks',
   t_("Sigur R\x{f3}s", 'Hoppipolla', 'Sigur Ros', 'Hoppipolla'));
ok('the mandatory artist gate still applies to tracks',
   !t_("Jane's Addiction", 'Jane Says', 'The Beatles', 'Jane Says'));
ok('NO compound tier on the track path — album-only, deliberately',
   !t_('Some Band', 'Hit Makers', 'Some Band', 'Hitmakers'));

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);
