#!/usr/bin/env perl
#
# t_bioreveal.pl — the artist-bio IN-PLACE reveal on the release detail page.
#
# Covers the change from a "Read more" DRILL-IN (which opened a separate view) to
# the Discography-style inline expand: collapsed preview + toggle, expanded full
# text + toggle, driven by %pageState and nextWindow=>'refresh'.
#
# Like the other suites here, it evals the REAL sub bodies out of Browse.pm (the
# `grab` trick) so it tests shipped code, not a paraphrase. LBF_BROWSE= points it
# at a mutated copy for ANTI-TESTING — do that for any assertion added here.
#
#   perl tools/t_bioreveal.pl
#   LBF_BROWSE=/tmp/mutated-Browse.pm perl tools/t_bioreveal.pl     # anti-test
#
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;

my $ROOT   = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), File::Spec->updir));
my $BROWSE = $ENV{LBF_BROWSE} || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Browse.pm');
my $STRINGS = File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'strings.txt');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    # scalar() on the caller's side is the t_trending_empty.pl lesson: a bare m//
    # or grep in list context shifts the args and makes the assertion self-fulfilling.
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
}

sub slurp {
    my ($f) = @_;
    open(my $fh, '<:encoding(UTF-8)', $f) or die "$f: $!";
    local $/; my $s = <$fh>; close $fh; return $s;
}

# Lift a named sub verbatim by brace-matching from its `sub NAME {`.
sub grab {
    my ($src, $name) = @_;
    $src =~ /^sub \Q$name\E\b\s*\{/mg or die "no sub $name\n";
    my $start = $-[0];
    my $i     = pos($src);
    my $depth = 1;
    while ($i < length($src) && $depth) {
        my $c = substr($src, $i++, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
    }
    die "unbalanced sub $name\n" if $depth;
    return substr($src, $start, $i - $start);
}

my $src = slurp($BROWSE);
my $API = $ENV{LBF_API} || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'API.pm');

# ---------------------------------------------------------------------------
# Harness: the minimum of Browse.pm's environment the two subs under test touch.
# ---------------------------------------------------------------------------
{
    package T;
    our %pageState;
    our $BIO_PREVIEW = 150;

    sub _cid { my ($c) = @_; return $c ? $c->{id} : '_none' }
    # Real string values, read from the shipped strings.txt below.
    our %STR;
    sub cstring { my (undef, $t) = @_; return $STR{$t} // "!$t!" }
    sub _pickValue {
        my ($rel, @keys) = @_;
        for my $k (@keys) { return $rel->{$k} if defined $rel->{$k} && length $rel->{$k} }
        return '';
    }
    # The bio block is the only part of _artistRows under test; stub the rest so
    # the sub can run end to end without the blocked-artist / VA machinery.
    sub _isVariousArtists { return 1 }
    sub _isBlocked        { return 0 }
    sub _blockedSet       { return {} }
    sub PAGE_MORE         { 'MORE_ICON' }
    sub PAGE_LESS         { 'LESS_ICON' }
    sub BIO_PREVIEW       { $BIO_PREVIEW }
    sub BIO_SENTENCES_PER_PARA { 3 }
    sub BIO_WRAP_MAX_COL       { 100 }
    sub BIO_WRAP_MIN_LINES     { 4 }
    sub BIO_HEADING_MAX_COL    { 80 }
    sub PROSE_INDENT           { '72px' }
    sub PROSE_BULLET_IND       { '1.2em' }
}

# Each prose ROW is one <div style='margin-left:72px'>…</div>, Discography's shape.
# prose_divs takes a LIST of rows and returns one entry per row, markup verbatim.
sub prose_divs {
    my @out;
    for my $n (map { ref $_ ? ($_->{name} // '') : ($_ // '') } @_) {
        next unless $n =~ m{^<div([^>]*)>(.*)</div>$}s;
        push @out, { style => $1, text => $2 };
    }
    return @out;
}
sub plain       { my $t = shift; $t =~ s{</?b>}{}g; $t =~ s{^\x{2022}\x{00A0}}{}; return $t }
# A heading is identified by its EXPLICIT weight, never by a <b> tag — see the
# comment in _proseBlock for why a bare <b> silently fails on a desktop browser.
sub prose_paras { return map { plain($_->{text}) } prose_divs(@_) }
sub headings_in { return map { plain($_->{text}) } grep { $_->{style} =~ /font-weight:bold/ } prose_divs(@_) }
sub bullets_in  { return map { plain($_->{text}) } grep { $_->{text} =~ m{^\x{2022}} } prose_divs(@_) }
# _bioParagraphs returns { text, heading } entries — most assertions only care
# about the text.
sub para_text { return map { $_->{text} } @_ }
sub prose_text {
    my ($n) = @_;
    return join(' ', prose_paras($n));
}

# Real strings, so a renamed/removed string fails the suite.
{
    my $st = slurp($STRINGS);
    for my $tok (qw(PLUGIN_LBF_READ_MORE PLUGIN_LBF_SHOW_LESS PLUGIN_LBF_ARTIST)) {
        if ($st =~ /^\Q$tok\E\n\tEN\t(.+)$/m) { $T::STR{$tok} = $1 }
    }
}

# _cleanBio is API.pm's, and it is HALF THE PIPELINE — at runtime MAI returns HTML,
# so what reaches _bioParagraphs has already been through it. Testing only the plain
# text the CLI shows is what hid the missing headings through four builds.
{
    package A;
    sub BIO_MAX { 20000 }
}
eval "package A; " . grab(slurp($API), '_cleanBio') . "; 1" or die "eval _cleanBio failed: $@";

for my $sub (qw(_escHtml _proseBlock _bioHardWrapped _bioLooksLikeHeading _bioBullet
                _bioBlocks _bioParagraphs _bioToggleRow _artistRows)) {
    my $code = grab($src, $sub);
    # %pageState is a file-scoped `my` in Browse.pm, so the lifted body refers to it
    # unqualified; re-declare it inside the eval so it aliases %T::pageState.
    eval "package T; our %pageState; $code; 1" or die "eval $sub failed: $@";
}

# ---------------------------------------------------------------------------
# Three paragraphs plus a blank chunk. NB single newlines are deliberately NOT used
# here — they are paragraph breaks too (see section 7), so putting one inside a
# paragraph would make this fixture claim the opposite of the intended behaviour.
my $LONG = join("\n\n",
    'Alpha paragraph that is quite long indeed and runs well past the preview cap so '
  . 'the collapsed view has to trim it back to a word boundary and append an ellipsis.',
    'Beta paragraph, the second one.',
    '',                                   # blank chunk — must be dropped
    'Gamma paragraph.');
my $SHORT = 'A short bio.';
my $CLIENT = { id => 'aa:bb:cc' };
my $REL    = { artist_credit_name => 'Sigur R\x{00F3}s' };

sub rows_for {
    %T::pageState = %{ $_[0] // {} };
    return T::_artistRows($REL, $CLIENT, undef, $_[1]);
}
sub names { return map { $_->{name} // '' } @_ }
sub texts { return map { prose_text($_->{name} // '') } @_ }

# The one prose row on an expanded page (there must be exactly one — that is the
# whole point of _proseBlock).
sub block_row {
    my @r = grep { ($_->{name} // '') =~ /^<div/ } @_;
    return @r == 1 ? $r[0] : undef;
}

print "\n1. COLLAPSED (default)\n";
{
    my @r = rows_for({}, $LONG);
    my @n = names(@r);
    ok(scalar(grep { $_ eq $T::STR{PLUGIN_LBF_READ_MORE} } @n) == 1, 'exactly one "Read more" row');
    ok(scalar(grep { $_ eq $T::STR{PLUGIN_LBF_SHOW_LESS} } @n) == 0, 'no "Show less" row');
    ok(scalar(grep { /\x{2026}$/ } @n) == 1,                          'preview is ellipsised');
    my ($prev) = grep { /\x{2026}$/ } @n;
    ok(length($prev) <= $T::BIO_PREVIEW + 1,                          'preview within BIO_PREVIEW');
    ok(scalar(grep { /Gamma paragraph/ } @n) == 0,                    'full text NOT present when collapsed');
    my ($tog) = grep { ($_->{name} // '') eq $T::STR{PLUGIN_LBF_READ_MORE} } @r;
    ok(($tog->{nextWindow} // '') eq 'refresh',                       'toggle uses nextWindow=>refresh');
    ok(($tog->{type} // '') eq 'link',                                'toggle is a link row');
    ok(($tog->{image} // '') eq 'MORE_ICON',                          'toggle carries the unfold_more icon');
    ok(ref $tog->{url} eq 'CODE',                                     'toggle has a url coderef');
}

print "\n2. THE TOGGLE ITSELF\n";
{
    my @r = rows_for({}, $LONG);
    my ($tog) = grep { ($_->{name} // '') eq $T::STR{PLUGIN_LBF_READ_MORE} } @r;
    my $got;
    $tog->{url}->($CLIENT, sub { $got = shift }, undef, $tog->{passthrough}[0]);
    # Material only acts on nextWindow when the response has ZERO items — a
    # non-empty response here would silently do nothing at all.
    ok(ref $got eq 'HASH' && ref $got->{items} eq 'ARRAY' && !@{ $got->{items} },
       'expand returns an EMPTY item list');
    ok(scalar(keys %{ $T::pageState{'aa:bb:cc'} || {} }) == 1, 'expand set exactly one flag');
    my ($k) = keys %{ $T::pageState{'aa:bb:cc'} };
    ok(scalar($k =~ /^bio:/), 'flag key is namespaced bio:');
}

print "\n3. EXPANDED\n";
{
    my @r0 = rows_for({}, $LONG);
    my ($tog0) = grep { ($_->{name} // '') eq $T::STR{PLUGIN_LBF_READ_MORE} } @r0;
    $tog0->{url}->($CLIENT, sub {}, undef, $tog0->{passthrough}[0]);
    my $state = { %T::pageState };

    my @r = rows_for($state, $LONG);
    my @n = names(@r);
    ok(scalar(grep { $_ eq $T::STR{PLUGIN_LBF_SHOW_LESS} } @n) == 1, 'exactly one "Show less" row');
    ok(scalar(grep { $_ eq $T::STR{PLUGIN_LBF_READ_MORE} } @n) == 0, 'no "Read more" row');

    # THE SHAPE: one row per PARAGRAPH, each Discography's indented prose div. Row
    # count is the thing that matters — Material gives every row a 48px floor, and
    # past LMS_MAX_NON_SCROLLER_ITEMS the level enters a fixed-height scroller where
    # a tall row is drawn over the one below. A correctly parsed bio is a handful of
    # rows; the 0.9.152 field bug was NINETY-TWO, from splitting at every wrapped line.
    my @prose = grep { ($_->{name} // '') =~ /^<div/ } @r;
    ok(scalar(@prose) == 3,                                          'one row per paragraph (blank chunk dropped)');
    my @paras = prose_paras(@prose);
    ok(scalar(@paras) == 3,                                          'each row holds exactly one paragraph');
    ok(scalar(grep { /Gamma paragraph/ } @paras) == 1,               'full text present');
    ok(scalar(grep { /\x{2026}$/ } @paras) == 0,                     'preview replaced, not appended');
    ok(scalar(grep { /\n/ } @paras) == 0,                            'no newline survives into a rendered paragraph');
    ok(scalar(grep { ($_->{type} // '') ne 'text' } @prose) == 0,    'every prose row is a text row');
    # Discography's indent: prose lines up with the avatar column of the icon rows
    # around it rather than sitting flush to the viewport edge.
    my @divs = prose_divs(@prose);
    ok(scalar(grep { $_->{style} =~ /margin-left:72px/ } @divs) == 3,
                                                                     'every prose row carries the 72px avatar indent');
    my ($tog) = grep { ($_->{name} // '') eq $T::STR{PLUGIN_LBF_SHOW_LESS} } @r;
    ok(($tog->{image} // '') eq 'LESS_ICON',                         'collapse row carries the unfold_less icon');

    my $got;
    $tog->{url}->($CLIENT, sub { $got = shift }, undef, $tog->{passthrough}[0]);
    ok(ref $got->{items} eq 'ARRAY' && !@{ $got->{items} },          'collapse returns an EMPTY item list');
    ok(scalar(keys %{ $T::pageState{'aa:bb:cc'} || {} }) == 0,
       'collapse DELETES the flag (no residue)');
}

print "\n4. SHORT BIO — no toggle at all\n";
{
    my @r = rows_for({}, $SHORT);
    my @n = names(@r);
    ok(scalar(grep { $_ eq $T::STR{PLUGIN_LBF_READ_MORE} } @n) == 0, 'no "Read more" for a short bio');
    ok(scalar(grep { $_ eq $T::STR{PLUGIN_LBF_SHOW_LESS} } @n) == 0, 'no "Show less" for a short bio');
    ok(scalar(grep { $_ eq $SHORT } @n) == 1,                        'short bio shown inline, verbatim');
}

print "\n5. NO REGRESSION TO THE OLD DRILL-IN\n";
{
    # The old shape returned the full bio as the toggle's OWN items, which opened a
    # separate view. A non-empty response is the signature of that regression, and
    # section 2 already asserts it is empty; this pins the source too, since a
    # future edit could reintroduce a drill row alongside the toggle.
    my $body = grab($src, '_artistRows');
    ok(scalar($body !~ /items\s*=>\s*\\\@paras/),      'no @paras drill-in payload remains');
    ok(scalar($body =~ /_bioToggleRow/),               '_artistRows uses _bioToggleRow');
    ok(scalar($src  =~ /^sub _bioToggleRow\b/m),       '_bioToggleRow is defined');
}

print "\n6. STATE STORE IS SHARED WITH PAGING\n";
{
    # Both features write to %pageState; a bio key must not look like a paging key
    # (_pageRow stores a numeric target under arweek:*) or one would clobber the other.
    my @r = rows_for({}, $LONG);
    my ($tog) = grep { ($_->{name} // '') eq $T::STR{PLUGIN_LBF_READ_MORE} } @r;
    ok(scalar($tog->{passthrough}[0]{key} !~ /^arweek:/), 'bio key cannot collide with a paging key');
    ok(defined $tog->{passthrough}[0]{on},                'toggle carries an explicit on/off flag');
}

print "\n7. PARAGRAPH SPLITTING — the shapes real Last.fm bios actually arrive in\n";
{
    # Measured on the live API: no <p> tags anywhere, so _cleanBio's </p><p> rule
    # almost never fires and the breaks are whatever the text happens to carry.
    my @blank  = para_text(T::_bioParagraphs("One para.\n\nTwo para.\n\nThree para."));
    ok(scalar(@blank) == 3, 'blank-line breaks split (Sigur Ros shape)');

    # The regression this section exists for: splitting on /\n{2,}/ alone threw away
    # every single-newline break, and Radiohead's bio has 9 of them to 4 blank ones.
    my @mixed = para_text(T::_bioParagraphs("One para.\n\nTwo para.\nThree para.\nFour para."));
    ok(scalar(@mixed) == 4, 'single newlines ALSO split (Radiohead shape)');

    ok(scalar(grep { /\n/ } @mixed) == 0, 'no newline survives into a paragraph');

    # Mildlife: 685 chars, not one newline in the whole thing. Nothing to split on,
    # so sentences are grouped rather than rendering one wall of text.
    my $blob = join(' ', map { "Sentence number $_ about the band." } 1 .. 9);
    my @grp  = para_text(T::_bioParagraphs($blob));
    ok(scalar(@grp) == 3,                        'break-less bio grouped into paragraphs (Mildlife shape)');
    ok(join(' ', @grp) eq $blob,                 'grouping does not alter a single character of the text');
    ok(scalar(grep { !/\S/ } @grp) == 0,         'no empty paragraph produced');

    # A short break-less bio is left alone — nothing to gain from chopping it up.
    my @short = para_text(T::_bioParagraphs('Just one short sentence about them.'));
    ok(scalar(@short) == 1, 'short break-less bio stays a single paragraph');
}

print "\n8. HTML SAFETY\n";
{
    # _cleanBio DECODES entities, so raw & and < reach us and would break the markup.
    ok(T::_escHtml('Simon & Garfunkel') eq 'Simon &amp; Garfunkel', 'ampersand escaped');
    ok(T::_escHtml('a <b> c') eq 'a &lt;b&gt; c',                   'angle brackets escaped');
    ok(T::_escHtml('say "hi"') eq 'say &quot;hi&quot;',             'double quotes escaped');
    my @rows = T::_proseBlock('AC/DC & <friends>', 'second & bit');
    my $all  = join('', map { $_->{name} } @rows);
    ok(scalar($all =~ /&amp;/ && $all =~ /&lt;friends&gt;/),
       'prose rows escape their text');
    ok(scalar($all !~ /<friends>/),              'no raw tag can leak into a row');
    ok(scalar(grep { ($_->{type} // '') ne 'text' } @rows) == 0, 'prose rows are text rows');
    ok(scalar(@rows) == 2,                       'one row per paragraph');
    ok(scalar(prose_paras(@rows)) == 2,          'every paragraph reaches a row');
    ok(scalar(() = T::_proseBlock()) == 0,       'no paragraphs yields no row at all');
}

print "\n9. HARD-WRAPPED SOURCE — the MAI shape (the 0.9.152 field bug)\n";
{
    # Verbatim from the live server: Tyondai Braxton's MAI bio, 5799 chars, wrapped
    # at <=78 columns, with setext headings. Under 0.9.151 this produced 92
    # one-line "paragraphs" and a 122-item detail page.
    my $WRAPPED = join("\n",
        'Tyondai Adaien Braxton (born October 26, 1978) is an American composer',
        'and musician. He has composed and performed music under his own name and',
        'collaboratively since the mid-1990s, including in the experimental rock',
        'group Battles from its formation in 2002 until his departure from the',
        'group in 2010.',
        '',
        'Early life',
        '----------',
        'As a teen, Braxton took musical inspiration from alternative rock bands',
        'like Nirvana and Sonic Youth, as well as from electronic music. He',
        'studied composition at the Hartt School.',
    );

    ok(scalar(T::_bioHardWrapped([split /\n/, $WRAPPED])), 'MAI shape detected as hard-wrapped');

    my @p = para_text(T::_bioParagraphs($WRAPPED));
    ok(scalar(@p) == 3, 'unwraps to real paragraphs, not one per source line');
    ok(scalar(grep { /Braxton \(born October 26, 1978\) is an American composer and musician/ } @p) == 1,
       'wrapped lines rejoin with a single space');
    ok(scalar(grep { /^-+$/ } @p) == 0,                   'setext underline dropped');
    ok(scalar(grep { $_ eq 'Early life' } @p) == 1,       'heading survives as its own paragraph');
    ok(scalar(grep { /Early life As a teen/ } @p) == 0,   'heading does not run into the body below it');

    # And the whole point: a HANDFUL of rows, not one per wrapped line. Expand
    # through the REAL toggle rather than hand-building the state key, so the
    # fixture cannot drift from however _artistRows chooses to key it.
    my @r0 = rows_for({}, $WRAPPED);
    my ($t0) = grep { ($_->{name} // '') eq $T::STR{PLUGIN_LBF_READ_MORE} } @r0;
    $t0->{url}->($CLIENT, sub {}, undef, $t0->{passthrough}[0]);
    my @r = rows_for({ %T::pageState }, $WRAPPED);
    my @prose = grep { ($_->{name} // '') =~ /^<div/ } @r;
    ok(scalar(@prose) == scalar(@p),                       'one row per parsed block, not per wrapped line');
    ok(scalar(prose_paras(@prose)) == scalar(@p),          'each row holds exactly one block');
}

print "\n11. SECTION HEADINGS ARE PRESERVED AND MARKED\n";
{
    # Two shapes in the SAME MAI bio, so the underline cannot be the only signal:
    # 'Early life' is setext-underlined, 'Early solo work...' is a bare short line.
    my $DOC = join("\n",
        'Tyondai Adaien Braxton (born October 26, 1978) is an American composer',
        'and musician who left the group in 2010.',
        '',
        'Early life',
        '----------',
        '',
        'As a teen, Braxton took musical inspiration from alternative rock bands',
        'like Nirvana and Sonic Youth, as well as from electronic music.',
        '',
        '',
        'Early solo work and Battles (2000-2009)',
        '',
        'After receiving his degree, Braxton moved to New York City in 2000. He',
        'became active in the experimental music scene there.',
    );

    my @p = T::_bioParagraphs($DOC);
    my @head = map { $_->{text} } grep { $_->{heading} } @p;
    ok(scalar(@head) == 2,                                    'both headings found');
    ok(scalar(grep { $_ eq 'Early life' } @head) == 1,        'setext-underlined heading marked');
    ok(scalar(grep { /^Early solo work/ } @head) == 1,        'bare short-line heading marked');
    ok(scalar(grep { $_->{heading} && /Braxton took/ } map { { %$_, } } @p) == 0,
                                                              'body text never marked as a heading');
    ok(scalar(grep { !$_->{heading} } @p) == 3,               'the three body paragraphs stay body');

    # Rendering: bold, with air above and a tight gap below so the title binds to
    # the body it introduces.
    my @rows = T::_proseBlock(@p);
    my @divs = prose_divs(@rows);
    my @bold = headings_in(@rows);
    ok(scalar(@bold) == 2,                                    'exactly two rows render bold');
    ok(scalar(grep { $_ eq 'Early life' } @bold) == 1,        'the heading text is the bold one');
    my ($eh) = grep { plain($_->{text}) eq 'Early life' } @divs;
    ok(scalar($eh->{style} =~ /font-weight:bold/),            'a heading carries an EXPLICIT weight');
    ok(scalar($eh->{text}  !~ /<b>/),                         'and NOT a bare <b>, which resolves to 400 from 200');
    ok(scalar($eh->{style} =~ /margin-left:72px/),            'and keeps the prose indent');
    ok(scalar(grep { $_->{style} =~ /font-weight:bold/ } @divs) == 2, 'only the headings are bold');

    # A heading must not be mistaken for prose that merely happens to be short.
    ok(!T::_bioLooksLikeHeading(['A short closing line.']),   'a full stop disqualifies a heading');
    ok(!T::_bioLooksLikeHeading(['one line', 'two lines']),   'a multi-line block is never a heading');
    ok(T::_bioLooksLikeHeading(['Discography:']),             'a trailing colon still reads as a heading');
}

print "\n10. THE DETECTOR MUST NOT FIRE ON DELIBERATE BREAKS\n";
{
    # Radiohead: single newlines that ARE breaks. Every line ends on a full stop,
    # so the mid-sentence signal is 0 and 0.9.151's behaviour is preserved.
    my $DELIB = "One para.\nTwo para.\nThree para.\nFour para.\nFive para.";
    ok(!T::_bioHardWrapped([split /\n/, $DELIB]),   'sentence-terminated lines are NOT a hard wrap');
    ok(scalar(T::_bioParagraphs($DELIB)) == 5,      'deliberate single newlines still split');

    # A long line proves there is no wrap column, even with mid-sentence breaks.
    my $LONGLINE = join("\n",
        'short line one that stops mid',
        'another that stops mid',
        'a third stopping mid',
        'and now a line that is very considerably longer than any plausible wrap column '
      . 'could ever be, running well past a hundred characters in total length');
    ok(!T::_bioHardWrapped([split /\n/, $LONGLINE]), 'a line past the wrap ceiling disqualifies');

    # Too few lines to judge.
    ok(!T::_bioHardWrapped(['one mid', 'two mid', 'three mid']), 'under the line floor, never wrapped');

    # Mildlife: no newlines at all — one line, so nothing to detect, and the
    # sentence grouping from 0.9.151 must still take over.
    my $blob = join(' ', map { "Sentence number $_ about the band." } 1 .. 9);
    ok(!T::_bioHardWrapped([$blob]),                'a single unbroken run is not a hard wrap');
    ok(scalar(T::_bioParagraphs($blob)) == 3,       'break-less bio still sentence-grouped');
}

print "\n12. A SETEXT HEADING SURVIVES A BIO THAT IS *NOT* HARD-WRAPPED\n";
{
    # The 0.9.152 regression Simon reported as "no title/headers". Every line ends on
    # a full stop, so _bioHardWrapped is correctly FALSE — and the old code therefore
    # skipped the structure parser entirely, losing the heading and rendering the
    # underline as a row of literal dashes.
    my $BIO = "The band formed in Leeds.\n"
            . "They released two albums.\n\n"
            . "Career\n------\n\n"
            . "They toured widely.\nThey then split up.";
    ok(!T::_bioHardWrapped([split /\n/, $BIO]),  'this fixture is NOT hard-wrapped');

    my @p = T::_bioParagraphs($BIO);
    ok(scalar(grep { $_->{text} =~ /^-+$/ } @p) == 0, 'the underline never becomes a paragraph');
    my @h = grep { $_->{heading} } @p;
    ok(scalar(@h) == 1,                          'the setext heading is still found');
    ok($h[0]{text} eq 'Career',                  'and it is the right block');
    ok(scalar(grep { $_->{heading} } grep { $_->{text} ne 'Career' } @p) == 0,
                                                 'no body line promoted to a heading');
    my @bold = headings_in(T::_proseBlock(@p));
    ok(scalar(@bold) == 1 && $bold[0] eq 'Career', 'and it renders bold');
}

print "\n13. BULLET LISTS ARE BULLETS, NOT HEADINGS\n";
{
    # Measured live: the "Roster" section of the MAI bio for Dean De Benedictis. Each
    # entry is one short line with no terminal punctuation, so the BARE-heading test
    # matches it exactly — every bullet rendered bold, which is what made the real
    # heading impossible to pick out.
    my $BIO = "The label signs a range of artists across several genres and has done\n"
            . "so since its relaunch in 2011.\n\n"
            . "Roster\n\n"
            . "  * Dean De Benedictis\n\n  * Smite Matter\n\n  * Zygote\n";
    my @p = T::_bioParagraphs($BIO);

    my @h = grep { $_->{heading} } @p;
    ok(scalar(@h) == 1,                    'exactly one heading, not four');
    ok($h[0]{text} eq 'Roster',            'the section title is the heading');

    my @b = grep { $_->{bullet} } @p;
    ok(scalar(@b) == 3,                    'all three list entries marked as bullets');
    ok(scalar(grep { $_->{heading} } @b) == 0, 'a bullet is never also a heading');
    ok($b[0]{text} eq 'Dean De Benedictis', 'the marker is stripped from the text');

    my @rows = T::_proseBlock(@p);
    ok(scalar(bullets_in(@rows)) == 3,     'each bullet renders with a marker');
    ok(scalar(headings_in(@rows)) == 1,    'and only the section title renders bold');
    my ($bd) = grep { $_->{text} =~ /Smite Matter/ } prose_divs(@rows);
    ok(scalar($bd->{text} =~ /^\x{2022}/),      'a bullet keeps its marker');
    ok(scalar($bd->{text} !~ /<b>/),            'a bullet is never bold');
    ok(scalar($bd->{style} =~ /text-indent:-/), 'bullets get a hanging indent');

    # The marker must need whitespace after it, or a hyphenated line opens a list.
    ok(!defined T::_bioBullet('e-mail was how they signed'), 'a hyphenated word is not a bullet');
    ok(defined T::_bioBullet('- a real dash bullet'),        'a dash plus space is');
}

print "\n14. THE REAL RUNTIME INPUT IS MAI's HTML, NOT PLAIN TEXT\n";
{
    # Verbatim shape of what MAI returns to a Material client (verified live with
    # `musicartistinfo biography html:1 artist:Lambchop`): a prepended stylesheet
    # <link>, <p> paragraphs, <b> inline, and <h2> section headings. Over the CLI the
    # same call returns plain text — which is why every earlier fixture was wrong.
    my $HTML =
        '<link rel="stylesheet" type="text/css" href="/plugins/MusicArtistInfo/html/mai.css" />'
      . '<p class="mw-empty-elt"></p>'
      . '<p><b>Lambchop</b>, originally <b>Posterchild</b>, is an American band from Nashville, Tennessee.</p>'
      . '<h2 data-mw-anchor="Description_and_history">Description and history</h2>'
      . '<p>Initially formed as a three piece in 1986 with Kurt Wagner and others.</p>'
      . '<h2>Personnel</h2>'
      . '<p>Summary of members as credited on studio albums.</p>'
      . '<h2>More online sources</h2><ul><li><a href="http://x">X</a></li><li><a href="http://y">Y</a></li></ul>';

    my $clean = A::_cleanBio($HTML);
    ok(scalar($clean !~ /</),                     'every tag is gone');
    ok(scalar($clean !~ /Lambchop ,/),            'inline tags leave NO stray space before punctuation');
    ok(scalar($clean =~ /Tennessee\.\n/),         'a </p> ends its paragraph with a real newline');

    my @p = T::_bioParagraphs($clean);
    my @h = grep { $_->{heading} } @p;
    ok(scalar(@h) == 2,                           'both <h2> headings survive as headings');
    ok($h[0]{text} eq 'Description and history',  'first heading is intact');
    ok($h[1]{text} eq 'Personnel',                'second heading is intact');
    ok(scalar(grep { $_->{text} =~ /Description and history\s+Initially/ } @p) == 0,
                                                  'a heading never merges into the body (the field bug)');
    ok(scalar(grep { $_->{text} =~ /^-+$/ } @p) == 0, 'the synthesised underline never renders');
    ok(scalar(grep { $_->{text} =~ /^[*\x{2022}]?\s*$/ } @p) == 0,
                                                  'emptied link items leave no bare bullets');
    ok(scalar(grep { $_->{text} eq 'More online sources' } @p) == 0,
                                                  'a trailing heading over nothing is dropped');

    my @rows = T::_proseBlock(@p);
    ok(scalar(headings_in(@rows)) == 2,           'exactly two rows render bold');
    ok(scalar(grep { $_->{style} =~ /font-weight:bold/ } prose_divs(@rows)) == 2,
                                                  'and they use an explicit weight');
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
