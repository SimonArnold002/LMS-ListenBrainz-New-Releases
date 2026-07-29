#!/usr/bin/env perl
# Verify the favurl LBF hands Listen Later, using LBF's real _attachFavUrl/_llRelType
# and LL's real _normRelType/relTypeFor — i.e. both ends of the handshake.
use strict;
use warnings;

my $LBF = '/Users/simona/Documents/GitHub/LMS-ListenBrainz-New-Releases/ListenBrainzFreshReleases/Browse.pm';
my $LL  = '/Users/simona/Documents/GitHub/LMS-Listen-to-Later/ListenLater/Sources.pm';

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
   . grab($LL,'relTypeFor') . grab($LL,'_normRelType') . "1;" or die $@;

# The MusicBrainz primary types the ListenBrainz feed actually emits.
my @CASES = (
    ['Album',     'a 12-track album'],
    ['EP',        'a 5-track EP'],
    ['Single',    'a 2-track single'],
    ['Broadcast', 'a radio session'],
    ['Other',     'an odd release'],
    ['',          'type unknown'],
);

printf "%-11s %-18s %-46s %s\n", 'MB type', 'LBF sends rt=', 'favurl', 'LL stores';
printf "%s\n", '-' x 104;
my $bad = 0;
for my $c (@CASES) {
    my ($mbType, $what) = @$c;
    my $rt = LBF::_llRelType($mbType);
    my $it = { _albumid => '12345' };
    LBF::_attachFavUrl($it, 'Qobuz', 'https://art/x.jpg', 'Jack White', '2026', $rt);
    my $fav = $it->{favorites_url};

    # Now the LL side: strip '&rt=' exactly as Plugin.pm does, and classify.
    my $got = ($fav =~ s{[?&]rt=([^&]*)}{}) ? $1 : undef;
    # A streaming add with no rt= falls back to LL's track-count guess; with 3 tracks
    # that guess says "ep" whatever the release really is.
    my $stored = LL::relTypeFor(service => $got, count => 3);

    my $expect = $mbType eq 'Single' ? 'single'
               : $mbType eq 'EP'     ? 'ep'
               : $mbType eq 'Album'  ? 'album'
               : 'ep';                       # no rt= -> LL's count guess (3 tracks)
    $bad++ unless ($stored // '') eq $expect;
    printf "%-11s %-18s %-46s %s%s\n",
        ($mbType || '(blank)'), ($rt // '(omitted)'),
        (length $fav > 44 ? substr($fav,0,43).'…' : $fav),
        ($stored // 'undef'),
        (($stored // '') eq $expect ? '' : "  <-- WRONG, expected $expect");
}
print "\nWithout the handshake, LL guesses from the resolved track count:\n";
printf "  a 3-track ALBUM  -> LL would store '%s' (wrong); with rt= it stores '%s'\n",
    LL::relTypeFor(count => 3), LL::relTypeFor(service => 'album', count => 3);
printf "  a 1-track ALBUM  -> LL would store '%s' (wrong); with rt= it stores '%s'\n",
    LL::relTypeFor(count => 1), LL::relTypeFor(service => 'album', count => 1);
printf "  an 8-track EP    -> LL would store '%s' (wrong); with rt= it stores '%s'\n",
    LL::relTypeFor(count => 8), LL::relTypeFor(service => 'ep', count => 8);

print $bad ? "\n$bad case(s) WRONG\n" : "\nall cases correct\n";
exit($bad ? 1 : 0);
