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
}

# Real strings, so a renamed/removed string fails the suite.
{
    my $st = slurp($STRINGS);
    for my $tok (qw(PLUGIN_LBF_READ_MORE PLUGIN_LBF_SHOW_LESS PLUGIN_LBF_ARTIST)) {
        if ($st =~ /^\Q$tok\E\n\tEN\t(.+)$/m) { $T::STR{$tok} = $1 }
    }
}

for my $sub (qw(_bioToggleRow _artistRows)) {
    my $code = grab($src, $sub);
    # %pageState is a file-scoped `my` in Browse.pm, so the lifted body refers to it
    # unqualified; re-declare it inside the eval so it aliases %T::pageState.
    eval "package T; our %pageState; $code; 1" or die "eval $sub failed: $@";
}

# ---------------------------------------------------------------------------
my $LONG = join("\n\n",
    'Alpha paragraph that is quite long indeed and runs well past the preview cap so '
  . 'the collapsed view has to trim it back to a word boundary and append an ellipsis.',
    "Beta paragraph with a\nsingle newline inside it.",
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
    ok(scalar(grep { /Gamma paragraph/ } @n) == 1,                   'full text present');
    ok(scalar(grep { /\x{2026}$/ } @n) == 0,                         'preview replaced, not appended');
    # One row per paragraph, blank chunks dropped.
    my @prose = grep { /paragraph/i } @n;
    ok(scalar(@prose) == 3,                                          'one row per paragraph (blank chunk dropped)');
    ok(scalar(grep { /\n/ } @n) == 0,                                'single newlines collapsed inside a paragraph');
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

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
