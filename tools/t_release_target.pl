#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use Digest::MD5 ();
open my $fh, '<:encoding(UTF-8)', "$FindBin::Bin/../ListenBrainzFreshReleases/Browse.pm" or die $!;
my $src = do { local $/; <$fh> };
sub grab { my $n = shift; $src =~ /^(sub \Q$n\E \{.*?^\})/ms or die $n; $1 }
{
    package T;
    our (%releaseTargets, $releaseTargetSweep, @opened, @weeksOpened);
    $releaseTargetSweep = 0;
    use constant RELEASE_TARGET_TTL => 86400;
    use constant RELEASE_TARGET_MAX => 10000;
    use constant ICON => 'icon';
    sub _relKey { $_[0]{release_mbid} // $_[0]{release_name} }
    sub _pickValue { my $r = shift; for (@_) { return $r->{$_} if $r->{$_} } '' }
    sub _displayType { 'Album' }
    sub _familyFor { () }
    sub _featuresOf { '' }
    sub _wantHeaders { 1 }
    sub cstring { $_[1] }
    sub _releaseDetail {
        my ($rel, $client, $cb) = @_;
        push @opened, $rel->{release_name};
        $cb->({items => [
            {type => 'text', name => $rel->{release_name}},
            {type => 'link', url => sub { $_[1]->({items => [{type => 'audio', name => 'track', url => 'service:track'}]}) }},
        ]});
    }
    sub _buildAllWeekItems {
        my ($weeks) = @_;
        my $week = $weeks->[0]{week_start};
        return [{ url => sub {
            push @weeksOpened, $week;
            $_[1]->({ items => [{ type => 'text', name => "Week $week" }] });
        } }];
    }
    package Plugins::ListenBrainzFreshReleases::API;
    sub coverArtUrl { 'cover' }
}
my $code = join "\n", map { grab($_) } qw(_releaseTarget _releaseAction _weekAction _weekTargetFeed _bindReleaseContext _releaseTargetFeed _buildReleaseItem);
eval "package T; no strict 'vars'; $code"; die $@ if $@;
my @rels = map { { release_mbid => "id-$_", release_name => "Album $_", artist => 'Artist' } } 0..89;
my @rows = map { T::_buildReleaseItem($_, undef) } @rels;
for my $index (0, 29, 30, 59, 60, 89) {
    my $action = $rows[$index]{itemActions}{items};
    is_deeply($action->{command}, ['listenbrainzfreshreleases', 'items'], "row $index uses the registered browse command");
    ok(!exists $action->{fixedParams}{item_id}, "row $index tap does not depend on a positional item_id");
    my $result;
    T::_releaseTargetFeed(undef, sub { $result = shift }, {params => $action->{fixedParams}});
    is($result->{items}[0]{name}, "Album $index", "row $index opens the displayed album across reveal boundaries");
}
my $saved = $rows[60]{itemActions}{items}{fixedParams};
@rels = reverse @rels; splice @rels, 4, 20;
my $result;
T::_releaseTargetFeed(undef, sub { $result = shift }, {params => $saved});
is($result->{items}[0]{name}, 'Album 60', 'background reorder and removals cannot redirect saved tap');
is($result->{query}{lbf_release}, $saved->{lbf_release}, 'default XMLBrowser actions and pagination retain the target');
is($result->{items}[1]{itemActions}{items}{fixedParams}{lbf_release}, $saved->{lbf_release}, 'detail link retains album target');
is($result->{items}[1]{itemActions}{items}{fixedParams}{item_id}, '1', 'detail link is relative to the stable album root');
my $nested;
$result->{items}[1]{url}->(undef, sub { $nested = shift });
for my $method (qw(play add insert)) {
    my $a = $nested->{items}[0]{itemActions}{$method};
    is_deeply($a->{command}, ['listenbrainzfreshreleases', 'playlist', $method], "$method uses the registered playback command");
    is($a->{fixedParams}{lbf_release}, $saved->{lbf_release}, "$method retains album target");
    is($a->{fixedParams}{item_id}, '1.0', "$method retains nested track position");
}
my $original = {items => [{type => 'audio', url => 'service:track', itemActions => {play => {command => ['service', 'play']}}}]};
my $bound = T::_bindReleaseContext($original, $saved->{lbf_release}, '');
is_deeply($bound->{items}[0]{itemActions}{play}, {command => ['service','play']}, 'service-specific playback action is preserved');
ok(!exists $original->{items}[0]{itemActions}{add}, 'binding does not mutate shared cached items');
$T::releaseTargets{$saved->{lbf_release}}{expires} = 0;
my $n = scalar @T::opened;
T::_releaseTargetFeed(undef, sub { $result = shift }, {params => $saved});
is(scalar(@T::opened), $n, 'expired target never opens another album');
is($result->{items}[0]{name}, 'PLUGIN_LBF_VIEW_EXPIRED', 'expired target asks for a refreshed list');
%T::releaseTargets = ();
T::_releaseTargetFeed(undef, sub { $result = shift }, {params => $saved});
is(scalar(@T::opened), $n, 'restart/eviction also fails closed');
my $unicode = T::_releaseTarget({release_name => '日本語 🎵'});
like($unicode, qr/^[a-f0-9]{32}$/, 'Unicode identity produces an ASCII-safe token');
like(grab('topLevel'), qr/return _releaseTargetFeed.*?exists \$args->\{params\}\{lbf_release\}/s, 'explicit release request bypasses dynamic feed traversal');
my $weekAction = T::_weekAction('2026-09-07');
is_deeply($weekAction->{command}, ['listenbrainzfreshreleases', 'items'], 'week row uses the registered browse command');
ok(!exists $weekAction->{fixedParams}{item_id}, 'week tap does not depend on a positional item_id');
my $weekResult;
T::_weekTargetFeed(undef, sub { $weekResult = shift }, { params => $weekAction->{fixedParams} });
is_deeply(\@T::weeksOpened, ['2026-09-07'], 'explicit week action opens the displayed week by natural key');
is($weekResult->{items}[0]{name}, 'Week 2026-09-07', 'week route returns that exact folder');
is($weekResult->{query}{lbf_week}, '2026-09-07', 'nested week actions retain the stable root');
my $weeksBefore = scalar @T::weeksOpened;
T::_weekTargetFeed(undef, sub { $weekResult = shift }, { params => { lbf_week => '../all' } });
is(scalar(@T::weeksOpened), $weeksBefore, 'invalid week target never broadens into another folder');
is($weekResult->{items}[0]{name}, 'PLUGIN_LBF_VIEW_EXPIRED', 'invalid week target fails closed');
my $unknownAction = T::_weekAction('');
ok(exists $unknownAction->{fixedParams}{lbf_week} && $unknownAction->{fixedParams}{lbf_week} eq '',
   'the dateless folder retains its empty-string natural key');
T::_weekTargetFeed(undef, sub { $weekResult = shift }, { params => $unknownAction->{fixedParams} });
is($T::weeksOpened[-1], '', 'the dateless week routes explicitly rather than falling back to the root');
ok(exists $weekResult->{query}{lbf_week} && $weekResult->{query}{lbf_week} eq '',
   'the dateless week query remains present for nested traversal');
like(grab('topLevel'), qr/return _weekTargetFeed.*?exists \$args->\{params\}\{lbf_week\}/s, 'explicit week request bypasses dynamic root traversal');
done_testing();
