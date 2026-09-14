#!/usr/bin/env perl
#
# t_cachememo.pl — generation-backed decoded-feed and processed-section reuse.
#
# The expensive path is DB::feedReleases: one thaw per release. A five-second
# memo only covered one XMLBrowser tap. These checks pin the longer reuse and,
# more importantly, each invalidation edge that makes it safe.

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
my $api = slurp($API);
my $br  = slurp($BR);

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

my ($pass, $fail) = (0, 0);
sub ok {
    my ($v, $msg) = @_;
    if ($v) { $pass++; print "  PASS  $msg\n" }
    else    { $fail++; print "  FAIL  $msg\n" }
}

print "\nDECODED FEED — generation, not five seconds\n", '-' x 74, "\n";
{
    # The sites use both $memoKey and the exact-week $key, so pin the material
    # property directly: every production read/write carries $feed as its final
    # argument rather than relying on a clock-only entry.
    my @getLines = grep { /_memoGet\(/ && !/^sub _memoGet/ } split /\n/, $api;
    my @setLines = grep { /_memoSet\(/ && !/^sub _memoSet/ } split /\n/, $api;
    ok(@getLines == 5 && !scalar(grep { !/,\s*(?:\$feed|\$q->\{feed\})\)/ } @getLines),
       'all feed and summary readers validate memo hits against their feed generation');
    ok(@setLines == 8 && !scalar(grep { !/,\s*(?:\$feed|\$q->\{feed\})\)/ } @setLines),
       'every production memo write records that feed generation');

    my ($ttl) = $api =~ /^(use constant FEED_MEMO_TTL\s*=>.*?;)/m;
    my $code = qq{
package MemoDB;
our (%GEN, %FAIL);
sub feedGeneration { return undef if \$FAIL{\$_[0]}; return \$GEN{\$_[0]} // 0 }
package Memo;
our %FEED_MEMO;
$ttl
} . grab($api, '_memoGet') . grab($api, '_memoSet') . grab($api, '_memoDrop') . q{
1;
};
    $code =~ s/Plugins::ListenBrainzFreshReleases::DB::feedGeneration/MemoDB::feedGeneration/g;
    eval $code or die "memo eval: $@";

    $MemoDB::GEN{all} = 7;
    my $source = [{ release_name => 'A' }];
    Memo::_memoSet('all-key', $source, 'all');
    ok(Memo::_memoGet('all-key', 'all') == $source,
       'the same store generation reuses the decoded arrayref');
    ok($Memo::FEED_MEMO{'all-key'}[0] - time() > 25 * 60,
       'the reuse window is measured in minutes, not the old five seconds');

    $MemoDB::GEN{all} = 8;
    ok(!defined Memo::_memoGet('all-key', 'all'),
       'a feed generation change invalidates the decoded copy immediately');
    ok(!exists $Memo::FEED_MEMO{'all-key'},
       'the stale entry is collected on that failed validity check');

    Memo::_memoSet('db-error', [], 'all');
    $MemoDB::FAIL{all} = 1;
    ok(!defined Memo::_memoGet('db-error', 'all') && !exists $Memo::FEED_MEMO{'db-error'},
       'an unverifiable generation fails closed and evicts an existing memo');
    Memo::_memoSet('db-error', [], 'all');
    ok(!exists $Memo::FEED_MEMO{'db-error'},
       'a memo is not created while its generation cannot be verified');
    $MemoDB::FAIL{all} = 0;

    Memo::_memoSet('expired', [], 'all');
    $Memo::FEED_MEMO{expired}[0] = time() - 1;
    ok(!defined Memo::_memoGet('expired', 'all'),
       'the TTL still bounds abandoned date/window keys');
}

print "\nPROCESSED SECTION — source version, settings and date window\n", '-' x 74, "\n";
{
    my ($ttl) = $br =~ /^(use constant SECTION_MEMO_TTL\s*=>.*?;)/m;
    my $code = q{
package ViewPrefs;
our %P;
sub new { bless {}, shift }
sub get { return $P{$_[1]} }
package Plugins::ListenBrainzFreshReleases::API;
our @WINDOW = ('2026-09-07', '2026-10-04');
sub sectionWindow { @WINDOW }
package View;
my @RELEASE_TYPES = qw(album single ep broadcast other compilation soundtrack live remix demo);
my $prefs = ViewPrefs->new;
my %SECTION_MEMO;
} . "$ttl\n" . grab($br, '_sectionSig') . grab($br, '_sectionBounds') . grab($br, '_sectionList') . q{
1;
};
    eval $code or die "section eval: $@";

    %ViewPrefs::P = (
        all_type_album => 1, all_artwork_only => 1, all_various => 1,
        all_weeks => 2, all_upcoming => 0,
        blocked_artists => [],
    );
    my $source = [{ release_name => 'A' }];
    my $builds = 0;
    my $build = sub { $builds++; return [@$source] };

    my $one = View::_sectionList('all', [$source], $build);
    my $two = View::_sectionList('all', [$source], $build);
    ok($one == $two && $builds == 1,
       'an unchanged version-stable source reuses the processed list');

    $ViewPrefs::P{all_type_single} = 1;
    my $three = View::_sectionList('all', [$source], $build);
    ok($three != $two && $builds == 2,
       'a section setting change rebuilds on the next walk');

    {
        no warnings 'once';
        @Plugins::ListenBrainzFreshReleases::API::WINDOW = ('2026-09-14', '2026-10-11');
    }
    my $four = View::_sectionList('all', [$source], $build);
    ok($four != $three && $builds == 3,
       'a Monday/effective-window rollover rebuilds even with the same source ref');

    my $replacement = [@$source];
    my $five = View::_sectionList('all', [$replacement], $build);
    ok($five != $four && $builds == 4,
       'a feed-generation replacement source invalidates processed reuse');

    my $sig = View::_sectionSig('all');
    $ViewPrefs::P{lastfm_api_key} = 'new enrichment configuration';
    ok(View::_sectionSig('all') eq $sig,
       'genre/artist enrichment is not baked into the section memo');
}

print "\n", '=' x 74, "\n$pass passed, $fail failed.\n";
exit($fail ? 1 : 0);
