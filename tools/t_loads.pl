#!/usr/bin/env perl
#
# t_loads.pl — every module must compile ON ITS OWN, with nothing preloaded.
#
#   perl tools/t_loads.pl
#
# WHY THIS EXISTS, AND IT IS THE MOST EXPENSIVE LESSON IN THE REPO SO FAR.
#
# 0.9.166 shipped a plugin that FAILED TO LOAD AT ALL:
#
#   Bareword "Plugins::ListenBrainzFreshReleases::DB::KEY_VERSIONS" not allowed
#     while "strict subs" in use at .../Plugin.pm line 394.
#   Error: Couldn't load Plugins::ListenBrainzFreshReleases::Plugin
#
# Every feed was empty, the menu was gone, and the log named a constant rather
# than anything a user could act on. The defect had been SEEN during the build:
# `perl -c Plugin.pm` failed exactly this way on its own and passed once DB.pm was
# preloaded, and that was written off as "production must load DB first". It does
# not, and nothing guaranteed it would.
#
# THE RULE THIS PINS: a constant in ANOTHER package is resolved at COMPILE time, so
# `Other::Package::CONSTANT` is only legal if that package was already compiled. A
# runtime `require` — even three lines above, even inside the same eval — is far
# too late. Use `Other::Package->CONSTANT` (a method call, resolved at runtime, and
# a constant ignores the invocant), or `use` the package at the top.
#
# WHY `perl -c` PER FILE IS NOT ENOUGH ON ITS OWN: the suites in tools/ load their
# subject with the rest of the plugin already in memory, which is precisely the
# condition that HIDES this. Each module here gets its own interpreter with only
# the LMS stubs available, which is the condition LMS itself imposes.
#
# ANTI-TEST (do this after touching it):
#   restore the bareword form in Plugin.pm  ->  this suite must go RED
#
# Exit 0 = every module loads. Exit 1 = at least one does not.

use strict;
use warnings;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);

my $ROOT   = File::Spec->catdir($FindBin::Bin, File::Spec->updir);
# LBF_PLUGIN points this at a plugin directory OTHER than the working tree —
# specifically, at an EXTRACTED COPY OF THE ZIP. That is not pedantry: what broke
# on the server was the shipped artefact, and a gate that only ever inspects the
# working tree cannot tell you the thing you are about to install actually loads.
my $PLUGIN = $ENV{LBF_PLUGIN} || File::Spec->catdir($ROOT, 'ListenBrainzFreshReleases');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    die "ok() called with no message\n" unless defined $what && length $what;
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
}

# ---------------------------------------------------------------------------
# A throwaway stub tree for the LMS modules the plugin uses. Deliberately DUMB:
# its only job is to let `use`/`require` succeed so the compile can proceed to the
# plugin's own code, which is what is under test.
# ---------------------------------------------------------------------------
my $STUB = tempdir(CLEANUP => 1);

sub stub {
    my ($pkg, $body) = @_;
    my @parts = split /::/, $pkg;
    my $file  = pop @parts;
    my $dir   = File::Spec->catdir($STUB, @parts);
    File::Path::make_path($dir) unless -d $dir;
    open(my $fh, '>', File::Spec->catfile($dir, "$file.pm")) or die $!;
    print $fh "package $pkg;\n", ($body // ''),
              "\nour \$AUTOLOAD; sub AUTOLOAD { return }\n1;\n";
    close $fh;
}
require File::Path;

stub('Slim::Utils::Log', <<'P');
use Exporter 'import'; our @EXPORT = qw(logger);
sub addLogCategory {} sub logger { bless {}, 'Slim::Utils::Log::L' }
package Slim::Utils::Log::L;
sub is_debug {0} sub is_info {0}
sub warn {1} sub error {1} sub info {1} sub debug {1}
package Slim::Utils::Log;
P
stub('Slim::Utils::Prefs', <<'P');
use Exporter 'import'; our @EXPORT = qw(preferences);
sub preferences { bless {}, 'Slim::Utils::Prefs::P' }
package Slim::Utils::Prefs::P;
sub get { undef } sub set {1} sub init {1} sub setValidate {1} sub migrate {1}
package Slim::Utils::Prefs;
P
stub('Slim::Utils::Strings', <<'P');
use Exporter 'import'; our @EXPORT_OK = qw(string cstring);
sub string {$_[0]} sub cstring {$_[1]}
P
stub('Slim::Utils::Cache',   'sub new { bless {}, shift } sub get {undef} sub set {1} sub remove {1}');
stub('Slim::Utils::Timers',  'sub setTimer {1} sub killTimers {1} sub killSpecific {1}');
stub('Slim::Utils::OSDetect','sub dirsFor { "/tmp" }');
stub('Slim::Utils::PluginManager', 'sub dataForPlugin { { version => "0.0.0" } } sub isEnabled {0}');
stub('Slim::Utils::Misc',    'sub msg {}');
stub('Slim::Utils::Unicode', 'sub utf8decode {$_[0]} sub utf8encode {$_[0]}');
stub('Slim::Utils::Versions','sub compareVersions {0}');
stub('Slim::Networking::SimpleAsyncHTTP', 'sub new { bless {}, shift } sub get {1} sub post {1}');
stub('Slim::Control::Request', 'sub addDispatch {1} sub executeRequest {1}');
stub('Slim::Music::Import',   'sub stillScanning {0}');
stub('Slim::Player::Client',  'sub clients { () }');
stub('Slim::Web::ImageProxy', 'sub registerHandler {1} sub getRightSize {undef}');
stub('Slim::Web::HTTP::CSRF', 'sub protectName {1} sub protectURI {1}');
stub('Slim::Web::Settings',   'sub new { bless {}, shift }');
stub('Slim::Web::Pages',      'sub addPageFunction {1}');
stub('Slim::Schema',          'sub search {undef}');
stub('Slim::Plugin::OPMLBased', 'sub initPlugin {1} sub _pluginDataFor {undef}');
stub('Slim::Menu::GlobalSearch', 'sub registerInfoProvider {1}');
stub('Plugins::MaterialSkin::HomeExtraBase', 'sub new { bless {}, shift }');
stub('JSON::XS::VersionOneAndTwo', <<'P');
use Exporter 'import'; our @EXPORT = qw(to_json from_json encode_json decode_json);
sub to_json {"{}"} sub from_json {{}} sub encode_json {"{}"} sub decode_json {{}}
P

# The plugin has to be reachable under its real package path.
File::Path::make_path(File::Spec->catdir($STUB, 'Plugins'));
symlink($PLUGIN, File::Spec->catdir($STUB, 'Plugins', 'ListenBrainzFreshReleases'))
    or die "symlink: $!";

# ---------------------------------------------------------------------------
print "\nEVERY MODULE COMPILES ON ITS OWN\n", '-' x 74, "\n";

# `main::WEBUI` is a constant LMS defines in its own bootstrap, not something the
# plugin can be expected to supply — so it is provided here, exactly as LMS does.
my $PRELUDE = 'BEGIN { *main::WEBUI = sub () { 0 }; *main::SCANNER = sub () { 0 }; '
            . '*main::ISWINDOWS = sub () { 0 }; *main::DEBUGLOG = sub () { 0 }; '
            . '*main::INFOLOG = sub () { 0 }; }';

my @MODULES = qw(DB API Browse DSTM Diag HomeExtras Settings Plugin);

for my $m (@MODULES) {
    my $pkg = "Plugins::ListenBrainzFreshReleases::$m";
    # A FRESH INTERPRETER PER MODULE, and that is the entire point: loading them
    # all into one process would let an earlier module satisfy a later one's
    # compile-time dependency, which is the exact illusion that shipped 0.9.166.
    my $out = qx{perl -I'$STUB' -e '$PRELUDE require $pkg; print "OK"' 2>&1};
    my $good = ($out // '') =~ /OK/;
    ok($good, "$m loads with nothing else preloaded");
    unless ($good) {
        my ($first) = split /\n/, ($out // '');
        print "        $first\n";
    }
}

# ---------------------------------------------------------------------------
print "\nNO CROSS-PACKAGE BAREWORD CONSTANTS\n", '-' x 74, "\n";
{
    # The source-level half. It catches the defect at the line rather than at the
    # symptom, and it keeps working even if a future stub accidentally preloads
    # something and makes the compile check above pass for the wrong reason.
    for my $m (@MODULES) {
        my $file = File::Spec->catfile($PLUGIN, "$m.pm");
        open(my $fh, '<:encoding(UTF-8)', $file) or die "$file: $!";
        local $/; my $src = <$fh>; close $fh;

        # A fully-qualified ALL-CAPS name NOT followed by `(` is a bareword. One
        # inside its OWN package is fine (the constant is declared in that file),
        # so those are excluded by name.
        my @bad;
        while ($src =~ /(Plugins::ListenBrainzFreshReleases::(\w+)::([A-Z][A-Z0-9_]{2,}))(?!\s*\()/g) {
            next if $2 eq $m;                      # same file, declared above
            push @bad, $1;
        }
        ok(!scalar(@bad),
           "$m.pm references no other package's constant as a bareword"
           . (@bad ? ' (found ' . join(', ', @bad) . ')' : ''));
    }
}

printf "\n%s\n%d passed, %d failed.\n", '=' x 74, $pass, $fail;
exit($fail ? 1 : 0);
