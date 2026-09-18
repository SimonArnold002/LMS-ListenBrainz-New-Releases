#!/usr/bin/env perl
use strict;
use warnings;

# ---------------------------------------------------------------------------
# THE SECTION DIVIDERS ON THE OLD WEB SKINS (Default / Classic).
#
# A client with no header support used to get `type => 'text'` carrying the
# plugin's `_svg.png`. On the two server-rendered skins that is not a divider,
# it is a PICTURE:
#   * Default (HTML/Default/xmlbrowser.html, the `weblink` BLOCK) has an explicit
#     `item.type == "text" && item.image` branch that wraps the row in
#     <a href="…Icon_svg.png" target="_blank"> — a thumbnail whose label opens the
#     raw PNG in a new tab.
#   * Classic (HTML/EN/xmlbrowser.html) sets hasArtwork from
#     `item.image && item.type == 'text'` — ONE such row flips the whole page into
#     gallery mode, so the divider becomes a tile among the album tiles.
# `type => 'textarea'` is rendered by BOTH templates as a bare line ahead of the
# row/tile wrapper: no cover, no controls, no link.
#
# THE DISCRIMINATOR IS `isWeb`, AND MATERIAL CANNOT REACH IT. Slim::Web::XMLBrowser
# passes isWeb => 1 at every feed level; Slim::Control::XMLBrowser — the JSON/CLI
# path Material, Jive, iPeng and the home shelves use — passes isControl and never
# isWeb. So every assertion here is paired with a CONTROL proving the Material and
# plain-controller shapes did not move.
#
# Anti-test with LBF_BROWSE=<mutated copy>.
# ---------------------------------------------------------------------------

my $BROWSE = $ENV{LBF_BROWSE}
    || "$ENV{HOME}/Documents/GitHub/LMS-ListenBrainz-New-Releases/ListenBrainzFreshReleases/Browse.pm";

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $msg) = @_;
    # Never die here: a harness that dies half way prints a SHORTER LIST, which reads
    # as a pass. A missing message almost always means a list-context match slid the
    # message into $cond — report that as the failure it is.
    unless (defined $msg && length $msg) {
        $fail++; print "  FAIL  HARNESS BUG: assertion with no message (list-context match?)\n";
        return 0;
    }
    if ($cond) { $pass++; print "  PASS  $msg\n" }
    else       { $fail++; print "  FAIL  $msg\n" }
    return $cond ? 1 : 0;
}
sub is_str {
    my ($got, $want, $what) = @_;
    $got = defined $got ? $got : '(undef)';
    return ok($got eq $want, "$what (got '$got')");
}
sub section { print "\n" . uc($_[0]) . "\n" . ('-' x 74) . "\n" }

sub slurp {
    my ($f) = @_;
    open(my $fh, '<:encoding(UTF-8)', $f) or die "$f: $!";
    local $/; my $s = <$fh>; close $fh; return $s;
}

# Brace-matched verbatim extraction (the regex scan, not substr-per-character —
# Browse.pm is half a megabyte of CHARACTER string; see t_coverwarm.pl).
sub grab {
    my ($src, $name) = @_;
    $src =~ /^sub \Q$name\E\b\s*\{/mg or die "no sub $name\n";
    my $start = $-[0];
    my $end   = length($src);
    my $depth = 1;
    while ($src =~ /([{}])/g) {
        $1 eq '{' ? $depth++ : $depth--;
        next if $depth;
        $end = pos($src);
        last;
    }
    return substr($src, $start, $end - $start) . "\n";
}

my $src = slurp($BROWSE);

# Minimal collaborators. _headerType is stubbed to the modern answer so a divider's
# Material type is a fixed, recognisable string; the rest only have to be callable.
{ package T;
  use constant ICON => 'lbf-icon.png';
  sub _headerType       { 'header-basic' }
  sub cstring           { $_[1] eq 'PLUGIN_LBF_FOLLOW_BY' ? 'By %s' : $_[1] }
  sub _fmtDate          { $_[0] }
  sub _weekLabel        { "W/C $_[1]" }
  sub _buildReleaseItem { { name => $_[0]{id} } }
}

# The heading style is READ from Browse.pm, not restated, so the suite follows it.
my ($styleDef) = $src =~ /^(use constant WEB_DIV_STYLE\b.*?;)\s*$/ms
    or die "no WEB_DIV_STYLE constant\n";
eval "package T; $styleDef 1;" or die "eval WEB_DIV_STYLE: $@";

for my $name (qw(_webSkin _divType _divImage _divName _escHtml _sectionHeader _dayDivider
                 _recommenderDivider _buildWeekly)) {
    my $body = grab($src, $name);
    eval "package T; our \$prefs; $body 1;" or die "eval $name: $@";
}

# The three client shapes this change is about.
my %SHAPE = (
    material => { useH => 1, web => 0 },   # features:hi over JSON-RPC
    web      => { useH => 0, web => 1 },   # Default / Classic
    plain    => { useH => 0, web => 0 },   # Jive, iPeng, a controller without 'h'
);

# =========================================================================
section('1. the discriminator and the two rules it feeds');

is_str(T::_webSkin({ isWeb => 1 }), 1, 'isWeb => 1 is a web skin');
is_str(T::_webSkin({ isControl => 1 }), 0, 'isControl (the JSON/CLI path Material uses) is NOT a web skin');
is_str(T::_webSkin({}), 0, 'a feed arg hash with neither flag is not a web skin');
is_str(T::_webSkin(undef), 0, 'a missing arg hash is not a web skin');

is_str(T::_divType(1, 1), 'header-basic', 'a header-capable client keeps its Material header even if isWeb were set');
is_str(T::_divType(0, 1), 'textarea',     'a web skin with no header support gets textarea');
is_str(T::_divType(0, 0), 'text',         'a non-web controller with no header support still gets plain text');

is_str(join('|', T::_divImage(0, 1)), '',                   'a web divider carries NO image');
is_str(join('|', T::_divImage(1, 0)), 'image|lbf-icon.png', 'a Material divider keeps its icon');
is_str(join('|', T::_divImage(0, 0)), 'image|lbf-icon.png', 'a plain-text divider keeps its icon');
is_str(join('|', T::_divImage(1, 0, 1)), '',                'noIcon still wins (detail-page headers)');

# =========================================================================
section('2. _sectionHeader — the Options / section dividers');

for my $shape (sort keys %SHAPE) {
    my $s   = $SHAPE{$shape};
    my $hdr = T::_sectionHeader(undef, 'PLUGIN_LBF_SECTION_OPTIONS', $s->{useH}, [], 0, $s->{web});
    my $want = $shape eq 'material' ? 'header-basic' : $shape eq 'web' ? 'textarea' : 'text';
    is_str($hdr->{type}, $want, "section header type for the $shape client");
    if ($shape eq 'web') {
        ok(!exists $hdr->{image}, 'the web section header has no image key at all (not merely an empty one)');
        ok(!exists $hdr->{url},   'the web section header carries no drill url');
    }
    else {
        is_str($hdr->{image}, 'lbf-icon.png', "the $shape section header keeps its icon");
    }
}

# =========================================================================
section('3. the WEEK divider, through the real _buildWeekly');

my $groups = [ { ws => '2026-09-14', rels => [ { id => 'r1' }, { id => 'r2' } ] } ];
for my $shape (sort keys %SHAPE) {
    my $s     = $SHAPE{$shape};
    my $items = T::_buildWeekly($groups, undef, $s->{useH}, undef, $s->{web});
    my $div   = $items->[0];
    my $want  = $shape eq 'material' ? 'header-basic' : $shape eq 'web' ? 'textarea' : 'text';
    is_str($div->{type}, $want, "week divider type for the $shape client");
    ok(scalar($shape eq 'web' ? $div->{name} =~ m{>W/C 2026-09-14</div>$} : $div->{name} eq 'W/C 2026-09-14'),
       "the $shape week divider still says which week it is");
    if ($shape eq 'web') {
        ok(!exists $div->{image}, 'the web week divider has no image — so Classic never flips to gallery mode');
    }
    else {
        is_str($div->{image}, 'lbf-icon.png', "the $shape week divider keeps its icon");
    }
    # THE CONTROL THAT MAKES THE REST MEAN ANYTHING: the releases are still there,
    # in order, whatever the divider became.
    is_str(join(',', map { $_->{name} } @{$items}[1 .. $#$items]), 'r1,r2',
           "the $shape week still renders both releases, in order");
}

# =========================================================================
section('4. the day / recommender dividers (the follow list)');

for my $shape (sort keys %SHAPE) {
    my $s    = $SHAPE{$shape};
    my $type = T::_divType($s->{useH}, $s->{web});
    my $day  = T::_dayDivider(undef, '2026-09-14', $type, $s->{useH}, [], $s->{web});
    my $rec  = T::_recommenderDivider(undef, 'someone', $type, $s->{useH}, [], $s->{web});
    my $want = $shape eq 'material' ? 'header-basic' : $shape eq 'web' ? 'textarea' : 'text';
    is_str($day->{type}, $want, "day divider type for the $shape client");
    is_str($rec->{type}, $want, "recommender divider type for the $shape client");
    if ($shape eq 'web') {
        ok(!exists $day->{image} && !exists $rec->{image}, 'neither web follow-list divider carries an image');
    }
    else {
        ok($day->{image} && $rec->{image}, "both $shape follow-list dividers keep their icon");
    }
}

# =========================================================================
section('4b. the web heading is styled — and escaped — and Material is not');

{
    my $web = T::_sectionHeader(undef, 'Options & Stuff', 0, [], 0, 1);
    ok(scalar($web->{name} =~ /^<div style="[^"]*font-weight:bold[^"]*">/),
       'the web section heading is a bold styled block');
    ok(scalar($web->{name} =~ /Options &amp; Stuff<\/div>$/),
       'the web heading text is HTML-escaped (& -> &amp;)');
    ok($web->{name} !~ /\n/, 'the web heading holds no newline (html_line_break would turn it into a <br>)');

    my $mat = T::_sectionHeader(undef, 'Options & Stuff', 1, [], 0, 0);
    is_str($mat->{name}, 'Options & Stuff', 'the Material heading name is the plain label, untouched');
    is_str(T::_divName('A & B', 1, 1), 'A & B',
           'a header-capable client never gets an HTML label, even if isWeb were set (same precedence as _divType)');
    my $pln = T::_sectionHeader(undef, 'Options & Stuff', 0, [], 0, 0);
    is_str($pln->{name}, 'Options & Stuff', 'a plain controller heading name is the plain label, untouched');

    # A recommender name comes from ListenBrainz — it must never become markup.
    my $rec = T::_recommenderDivider(undef, '<b>x</b>', 'textarea', 0, [], 1);
    ok(scalar($rec->{name} =~ /By &lt;b&gt;x&lt;\/b&gt;<\/div>$/) && $rec->{name} !~ /<b>x/,
       'a ListenBrainz username in a web divider is escaped, never rendered as HTML');

    my $wk = T::_buildWeekly($groups, undef, 0, undef, 1)->[0];
    ok(scalar($wk->{name} =~ /^<div style=.*>W\/C 2026-09-14<\/div>$/), 'the web week heading is styled');
    is_str(T::_buildWeekly($groups, undef, 1, undef, 0)->[0]{name}, 'W/C 2026-09-14',
           'the Material week heading is the plain label, untouched');
}

# =========================================================================
section('5. the wiring — a view that renders dividers must KNOW it is a web skin');

# The helper being right is worth nothing if a view never asks. Every entry point
# that works out header support has to work out web-ness from its own $args at the
# same time: `features` reaches the top feed only (hence the passthrough dance),
# but isWeb is passed at EVERY level, so there is no excuse for a view to miss it.
my $stripped = join "\n", map { my $l = $_; $l =~ s/^\s*#.*$//; $l } split /\n/, $src;

for my $entry (qw(topLevel fetchForYou fetchAll resolveFollowFeed
                  resolveTrendingAlbums _weekTargetFeed _releaseTargetFeed)) {
    my $body = grab($stripped, $entry);
    ok(scalar($body =~ /_webSkin\s*\(/), "$entry works out whether the client is a web skin");
}

# And the divider CONSTRUCTORS must go through the one image rule, or a future
# divider silently reinstates the picture.
for my $ctor (qw(_sectionHeader _dayDivider _recommenderDivider _buildWeekly)) {
    my $body = grab($stripped, $ctor);
    ok(scalar($body =~ /_divImage\s*\(/ && $body !~ /image\s*=>\s*ICON/),
       "$ctor takes its image from the one rule, never a bare ICON");
    ok(scalar($body =~ /name\s*=>\s*_divName\s*\(/),
       "$ctor takes its label from _divName, so a web heading is styled and escaped");
}

# =========================================================================
section('6. the web pass — rows, toggles and the CLI detour (_webify)');

# The dividers were only the first thing the old skins drew wrongly. A release page is
# mostly plain `text` rows (escaped, so the bio's markup showed as code, and each given
# a placeholder cover in Default), its toggles rely on nextWindow (which the web skins
# do not have), and it is reached through an itemActions CLI detour that drops isWeb.
{ package Slim::Web::ImageProxy;
  sub proxiedImage { my ($u) = @_; (my $e = $u) =~ s/([^A-Za-z0-9._~-])/sprintf('%%%02X', ord $1)/ge;
                     return "imageproxy/$e/image.jpg" }
}
for my $name (qw(_webify _webifyItem _feedIsEmpty _webImageSrc _webBounce)) {
    my $body = grab($src, $name);
    eval "package T; $body 1;" or die "eval $name: $@";
}

# 6a — the discriminator now sees the CLI detour.
ok(T::_webSkin({ isWeb => 1 }), 'isWeb is a web skin');
ok(T::_webSkin({ isControl => 1, params => { feedMode => 1, lbf_week => '2026-09-14' } }),
   'a CLI request carrying feedMode (the web renderer asking for the RAW feed) is a web skin');
ok(!T::_webSkin({ isControl => 1, params => { menu => 1, lbf_week => '2026-09-14' } }),
   'CONTROL: a Material/Jive request with no feedMode is NOT a web skin');
ok(!T::_webSkin({ isControl => 1, params => { lbf_release => 'tok' } }),
   'CONTROL: a sub-feed that only got the query back is not, on its own, a web skin');

# 6b — plain rows.
my $w = T::_webify({ items => [
    { name => 'Artist: A <b> & "C"', type => 'text' },
    { name => "<div style='margin-left:72px;font-weight:bold'>Early life</div>", type => 'text', _lbfProse => 1 },
    { name => 'Artist: After', type => 'text', image => 'https://img.example/x.jpg' },
    { name => 'Local', type => 'text', image => 'plugins/X/local.png' },
    { name => 'Play', type => 'link', url => 'qobuz://1', image => 'i.png' },
    { name => '<div>heading</div>', type => 'textarea' },
    { name => 'Track', type => 'audio', url => 'qobuz://2.flac' },
], title => 'T' })->{items};
is_str($w->[0]{type}, 'textarea', 'a plain text row becomes a textarea (no placeholder cover)');
is_str($w->[0]{name}, 'Artist: A &lt;b&gt; &amp; &quot;C&quot;',
       '... and its text is ESCAPED, since a textarea is printed raw');
ok(scalar($w->[1]{name} =~ /^<div style='margin:2px 0 6px 0;font-weight:bold'>Early life<\/div>$/),
   'our own prose markup is kept as markup, minus the 72px Material avatar indent');
ok(scalar($w->[2]{name} =~ m{<img src="/imageproxy/https%3A%2F%2Fimg\.example%2Fx\.jpg/image_100x100_o\.jpg"}),
   'a text row\'s remote image is drawn inline, through the server image proxy');
ok(!exists $w->[2]{image}, '... and the row itself carries NO image (no thumbnail link, no Classic gallery)');
ok(scalar($w->[3]{name} =~ m{<img src="/plugins/X/local\.png"}), 'a local image path is made absolute, not proxied');
is_str($w->[4]{type}, 'link', 'CONTROL: a link row keeps its type');
is_str($w->[4]{image}, 'i.png', 'CONTROL: ... and its image');
is_str($w->[5]{name}, '<div>heading</div>', 'CONTROL: a divider that is already a textarea is untouched');
is_str($w->[6]{type}, 'audio', 'CONTROL: an audio row is untouched');
ok(!exists $w->[1]{_lbfProse}, '... and the prose marker is consumed, not passed on to the skin');

# 6b' — the prose test is the MARKER, never the name. A short bio is emitted verbatim
# and _cleanBio decodes &lt; LAST, so an entity-encoded "<div style='" from a Last.fm
# or Wikipedia bio (or a MusicBrainz track title) reaches _webify as real markup.
my $evil = "<div style='x'><script>alert(1)</script></div>";
my $e = T::_webify([ { name => $evil, type => 'text' } ])->[0];
is_str($e->{type}, 'textarea', 'an UPSTREAM row that merely starts like our markup is still a textarea');
ok(index($e->{name}, '<script>') < 0 && index($e->{name}, '&lt;script&gt;') >= 0,
   '... and it is ESCAPED, so no script reaches a raw-printing web skin');
{ package T;
  use constant PROSE_INDENT     => '72px';
  use constant PROSE_BULLET_IND => '1.2em';
}
eval 'package T; ' . grab($src, '_proseBlock') . ' 1;' or die "eval _proseBlock: $@";
my @pb = T::_proseBlock('Body <b>', { text => 'Early life', heading => 1, bullet => 0 });
ok(@pb == 2 && !grep({ !$_->{_lbfProse} } @pb), '_proseBlock marks EVERY row it builds');
my $pw = T::_webify(\@pb);
ok(scalar($pw->[0]{name} =~ /^<div style='margin:2px 0 6px 0;'>Body &lt;b&gt;<\/div>$/),
   '... and the real thing still renders as markup, its own text escaped (got \'' . $pw->[0]{name} . "')");

# 6b'' — a release page reached through a CODEREF (not the lbf_release target) must
# know it is on a web skin: `features` never reaches a sub-feed, so without the flag
# $useH defaulted to 1 and the page came out Material-shaped (header dividers with the
# icon, the bio collapsed behind Read more, no web-only icons).
{ package T2;
  our @seen;
  sub _releaseDetail    { @seen = @_; }
  sub _buildReleaseItem { { name => 'x', type => 'text' } }
  sub cstring           { '%s' }
}
eval 'package T2; ' . grab($src, '_webSkin') . grab($src, '_trendingAlbumRel') . grab($src, '_trendingAlbumRow') . ' 1;'
    or die "eval _trendingAlbumRow: $@";
my $tr = T2::_trendingAlbumRow(undef, { artist => 'A', title => 'B', breadth => 2 });
is_str($tr->{type}, 'link', 'CONTROL: an unmapped Trending Albums row still becomes a link');
$tr->{url}->('c', sub {}, { isWeb => 1 });
is_str($T2::seen[4] // 0, 1, 'the Trending fallback row tells _releaseDetail it is on a web skin');
$tr->{url}->('c', sub {}, { isControl => 1 });
is_str($T2::seen[4] // 0, 0, 'CONTROL: ... and does not for Material');
my $rd = grab($src, '_releaseDetail');
ok(scalar($rd =~ /\$useH\s*=\s*\$isWeb\s*\?\s*0\s*:\s*1\s+unless\s+defined\s+\$useH/),
   '_releaseDetail defaults $useH OFF on a web skin, ON otherwise');
(my $code = $src) =~ s/^\s*#.*$//mg;
my @calls;
push @calls, $1 while $code =~ /(?<!sub )(_releaseDetail(\((?:[^()]++|(?2))*\)))/g;
my @bare = grep { !/_webSkin\(/ } @calls;
ok(@calls >= 4, 'CONTROL: the call-site scan finds the release page\'s callers (' . scalar(@calls) . ')');
ok(!@bare, 'every _releaseDetail call site passes the web flag' . (@bare ? " — bare: @bare" : ''));

# 6c — wrapped children: isWeb re-stamped, output webified, nextWindow answered.
my ($seenArgs, $answer);
my $orig = { lbf => 1 };
my $row = T::_webifyItem({ name => 'Read more', type => 'link', nextWindow => 'refresh',
                           url => sub { $seenArgs = $_[2]; $_[1]->($answer) } });
$answer = { items => [] };
my $got; $row->{url}->(undef, sub { $got = shift }, $orig, {});
ok($seenArgs->{isWeb} && $seenArgs->{lbf}, 'a wrapped child is called WITH isWeb, and the rest of its args');
ok(!exists $orig->{isWeb}, '... without writing into the caller\'s own args hash');
ok(scalar(($got->{items}[0]{name} // '') =~ /i\.splice\(-1,1\)/),
   'an EMPTY answer from a refresh row becomes a bounce back ONE level');
is_str($got->{items}[0]{type}, 'textarea', '... drawn as a raw textarea, so its script runs');

my $parent = T::_webifyItem({ name => 'Show 3', type => 'link', nextWindow => 'parent',
                              url => sub { $_[1]->({ items => [] }) } });
$got = undef; $parent->{url}->(undef, sub { $got = shift }, {});
ok(scalar(($got->{items}[0]{name} // '') =~ /i\.splice\(-2,2\)/),
   'an EMPTY answer from a parent row bounces back TWO levels');

$answer = { items => [ { name => 'picker <x>', type => 'text' } ] };
$got = undef; $row->{url}->(undef, sub { $got = shift }, {});
is_str($got->{items}[0]{type}, 'textarea',
       'a refresh row that DOES answer (the Bandcamp picker) is shown, and its rows webified');
ok(scalar(($got->{items}[0]{name} // '') !~ /<script/), '... and is NOT bounced');

my $plain = T::_webifyItem({ name => 'Block', type => 'link', url => sub { $_[1]->({ items => [] }) } });
$got = undef; $plain->{url}->(undef, sub { $got = shift }, {});
ok(ref $got eq 'HASH' && !@{ $got->{items} }, 'CONTROL: an empty answer from a row with NO nextWindow is passed through');

my $deep = T::_webifyItem({ name => 'Week', type => 'link', url => sub {
    $_[1]->({ items => [ { name => 'Inner', type => 'link', nextWindow => 'refresh',
                           url => sub { $seenArgs = $_[2]; $_[1]->({ items => [] }) } } ] });
} });
$got = undef; $deep->{url}->(undef, sub { $got = shift }, {});
$seenArgs = undef; my $g2;
$got->{items}[0]{url}->(undef, sub { $g2 = shift }, { params => { lbf_release => 't' } });
ok($seenArgs && $seenArgs->{isWeb}, 'a GRANDCHILD is wrapped too, so isWeb survives the CLI detour\'s query-only args');
ok(scalar(($g2->{items}[0]{name} // '') =~ /<script/), '... and its toggle still bounces');

my $nested = T::_webify([ { name => 'x', type => 'link', items => [ { name => 'a<b', type => 'text' } ] } ]);
is_str($nested->[0]{items}[0]{name}, 'a&lt;b', 'inline nested items are webified as well');

# 6c2 — an Options block is CLOSED by a heading on a web skin (Classic has no row
# covers, so the options ran straight into the releases), and only there.
{ my $b = grab($src, '_webListHead'); eval "package T; $b 1;" or die "eval _webListHead: $@"; }
my @wh = T::_webListHead(1, 'W/C 14 September 2026');
ok(@wh == 1 && $wh[0]{type} eq 'textarea' && $wh[0]{name} =~ /W\/C 14 September 2026/
   && $wh[0]{name} =~ /font-weight:bold/, 'a web skin gets a styled heading after Options');
ok(!T::_webListHead(0, 'x'), 'CONTROL: Material / a plain controller gets NO extra row, so row positions do not move');
my $wk = grab($stripped, '_buildAllWeekItems');
ok(scalar($wk =~ /\@opt,\s*\@head,\s*\@tiles/), 'an All Releases week puts the heading between Options and the releases');
ok(scalar($wk =~ /_renderSlots\(scalar\(\@opt\)\s*\+\s*1\s*\+\s*scalar\(\@head\)/),
   '... and the cover-focus slot map counts it, so the focus still points at the right rows');
my $ta = grab($stripped, '_trendingAlbumsResult');
ok(scalar($ta =~ /\@opt,\s*_webListHead\(/), 'Trending Albums closes its Options block the same way');

# 6c3 — no Show more paging on a web skin: the skins page every list themselves (50
# a page), so a grown list pushed the new rows and the next paging row onto the
# skin's page 2 and the tap looked dead.
{ package T;
  use constant PAGE_SIZE => 30; use constant PAGE_MORE => 'more.png'; use constant PAGE_LESS => 'less.png';
  our %pageState; sub _cid { 'p1' }
  sub _pageRow { my (undef, undef, $t, $n) = @_; return { name => $n, type => 'link', _target => $t } }
}
{ my $b = grab($src, '_pageSection'); eval "package T; our %pageState; $b 1;" or die "eval _pageSection: $@"; }
my @many = (1 .. 100);
my ($vis, $pg) = T::_pageSection(undef, 'k', \@many, 1);
ok(@$vis == 100 && !@$pg, 'a web skin gets the WHOLE week and no Show more / Show all / Show less rows');
($vis, $pg) = T::_pageSection(undef, 'k', \@many);
ok(@$vis == 30 && @$pg == 2, 'CONTROL: Material still gets 30 rows plus Show more and Show all');
$T::pageState{p1}{k} = 60;
($vis, $pg) = T::_pageSection(undef, 'k', \@many, 1);
ok(@$vis == 100 && !@$pg, '... and a page state left over from Material does not shorten the web list');
my $wk2 = grab($stripped, '_buildAllWeekItems');
ok(scalar($wk2 =~ /_pageSection\(\$c,\s*\$key,\s*_frozenOrder\([^)]*\),\s*\$web\)/),
   'the All Releases week tells _pageSection it is a web skin');
ok(scalar($wk2 =~ /_withGenres\(\$visRel,\s*\$draw,\s*\$web\s*\?\s*GENRE_WARM_MAX/),
   '... and widens the genre read to match, so rows past 150 keep their genre');

# 6c4 — the Settings row. A bare /plugins/… path is served in the SERVER's default
# skin, so the old skins opened a Material-styled settings page.
my ($wsl) = $src =~ /use constant WEB_SETTINGS_LINK\s*=>\s*'([^']+)'/;
is_str($wsl, '../ListenBrainzFreshReleases/settings.html', 'the web settings link is RELATIVE to the browse page');
{
    require URI;
    my $u = URI->new_abs($wsl, 'http://plex:9000/Classic/plugins/listenbrainzfreshreleases/index.html?player=x&index=10');
    is_str($u->path, '/Classic/plugins/ListenBrainzFreshReleases/settings.html',
           '... so from a skin\'s browse page it stays inside that skin');
}
my $tl2 = grab($stripped, 'topLevel');
ok(scalar($tl2 =~ /weblink\s*=>\s*\(\$isWeb\s*\?\s*WEB_SETTINGS_LINK\s*:\s*'\/plugins\/ListenBrainzFreshReleases\/settings\.html'\)/),
   'the Settings row uses it on a web skin, and Material keeps the absolute path');

# 6d — the wiring: topLevel applies it, and only for a web skin.
my $tl = grab($stripped, 'topLevel');
ok(scalar($tl =~ /if\s*\(\s*_webSkin\(\$args\)[^)]*\)\s*\{[^}]*_webify\(/s),
   'topLevel wraps its callback in _webify ONLY when the client is a web skin');
my $wrapAt = index($tl, '_webify(');
my $tgtAt  = index($tl, '_releaseTargetFeed(');
ok($wrapAt >= 0 && $tgtAt > $wrapAt,
   'the wrap happens BEFORE the release/week target routes, which are how the web skins reach them');
ok(scalar($src =~ /^PLUGIN_LBF_WEB_BACK\b/m) || do {
       my $st = slurp(($BROWSE =~ s{Browse\.pm$}{strings.txt}r));
       scalar($st =~ /^PLUGIN_LBF_WEB_BACK\n\tEN\t\S/m) },
   'the bounce page\'s link text exists in strings.txt');

print "\n" . ('=' x 74) . "\n";
print "$pass passed, $fail failed.\n";
exit($fail ? 1 : 0);
