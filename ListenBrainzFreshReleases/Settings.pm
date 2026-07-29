package Plugins::ListenBrainzFreshReleases::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

my $prefs = preferences('plugin.listenbrainzfreshreleases');
my $log   = logger('plugin.listenbrainzfreshreleases');

# Every boolean/checkbox pref on the settings page. An unchecked checkbox posts
# nothing, so handler() coerces each of these to an explicit 0/1 (see the note in
# handler) — otherwise a turned-off toggle stored as undef reads back ON through
# the `// <default>` guards used across the plugin.
#
# KEEP IN SYNC: @TYPE_KEYS is the release-type list, and it is duplicated in three
# other places that must all agree — the foryou_type_*/all_type_* names in prefs(),
# the $prefs->init defaults in Plugin.pm, and the checkboxes in settings.html. A type
# added there but missed here silently loses its 0/1 coercion (reintroducing the
# undef-reads-ON bug for that one type).
my @TYPE_KEYS = qw(album single ep broadcast other compilation soundtrack live remix demo);
my @CHECKBOX_PREFS = (
    qw(play_via people_follow prefer_library debug_log muspy_future),
    qw(foryou_past foryou_future foryou_artwork_only foryou_various),
    qw(all_past all_future all_artwork_only all_various),
    (map { "foryou_type_$_" } @TYPE_KEYS),
    (map { "all_type_$_"    } @TYPE_KEYS),
);

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_LISTENBRAINZ_FRESH_RELEASES');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/ListenBrainzFreshReleases/settings.html');
}

sub prefs {
    return ($prefs, qw(
        username token lastfm_api_key muspy_userid muspy_future muspy_future_months days play_via people_follow prefer_library mb_base_url genre_lookup debug_log
        svc_priority_qobuz svc_priority_bandcamp svc_priority_tidal svc_priority_deezer
        foryou_past foryou_future foryou_artwork_only foryou_various
        foryou_type_album foryou_type_single foryou_type_ep foryou_type_broadcast foryou_type_other
        foryou_type_compilation foryou_type_soundtrack foryou_type_live foryou_type_remix foryou_type_demo
        all_past all_future all_artwork_only all_various
        all_type_album all_type_single all_type_ep all_type_broadcast all_type_other
        all_type_compilation all_type_soundtrack all_type_live all_type_remix all_type_demo
    ));
}

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    if ($params->{saveSettings}) {
        # Coerce every checkbox pref to an EXPLICIT 0/1 before SUPER::handler
        # persists it. An unchecked HTML checkbox submits NOTHING, so
        # $params->{pref_x} is undef — and the base handler would then store undef.
        # Because the whole plugin reads these as `$prefs->get('x') // <default>`,
        # a stored undef is indistinguishable from "never set" and the `//` default
        # (e.g. // 1 for the past/various/artwork toggles) flips a just-turned-OFF
        # box back ON — the toggle could never be disabled (all_past / foryou_past
        # etc.). Forcing an explicit 0 means `0 // 1` stays 0 (defined), so OFF
        # sticks; a ticked box arrives as "1" and stays 1.
        #
        # Guard: only coerce when this is the REAL settings form (an unchecked box
        # and a box absent because the POST is partial/non-form are indistinguishable,
        # so a blind coercion would zero every toggle on a partial save — the same
        # hazard the svc_priority block below guards against). `pref_days` is a
        # number field the full form always submits, so its presence confirms the
        # form was posted; a partial POST skips coercion and falls back to the base
        # handler (same philosophy as the svc_priority "keep current on partial" rule).
        if (exists $params->{pref_days}) {
            for my $cb (@CHECKBOX_PREFS) {
                $params->{"pref_$cb"} = $params->{"pref_$cb"} ? 1 : 0;
            }
        }

        # Clamp the numeric prefs by writing the sanitised value back into the
        # params BEFORE SUPER::handler runs. These prefs are in the prefs() list,
        # so the base handler re-sets each one from $params->{pref_*}; setting the
        # pref directly here would simply be overwritten by the raw input.
        my $days = $params->{pref_days};
        $days = 14 unless defined $days && $days =~ /^\d+$/;
        $days = 1  if $days < 1;
        $days = 90 if $days > 90;
        $params->{pref_days} = $days + 0;

        # Normalise the service priorities to integers 0-9 (0 = never search).
        # If a field is absent from the POST (a partial / non-form submission)
        # keep the CURRENT saved value rather than forcing 0 — forcing 0 would
        # silently disable that service on any incomplete save.
        for my $svc (qw(qobuz bandcamp tidal deezer)) {
            my $p = $params->{"pref_svc_priority_$svc"};
            if (defined $p && $p =~ /^\d+$/) {
                $p = 9 if $p > 9;
                $params->{"pref_svc_priority_$svc"} = $p + 0;
            }
            else {
                $params->{"pref_svc_priority_$svc"} = $prefs->get("svc_priority_$svc") // 0;
            }
        }

        # MusicBrainz base URL: trim; a blank field STAYS blank so _mbBase can
        # auto-detect a same-host mirror (and fall back to the public API when
        # none is found). Storing the public URL on blank would defeat that — the
        # settings.html placeholder communicates the default in the empty box.
        # API::_mbBase normalises the trailing slash at read time.
        # Guard: a scheme-less entry (e.g. a bare mirror host "your-server:5000/ws/2") is
        # unfetchable and would fail EVERY MB lookup silently (tracklist, genres, DSTM
        # artist resolve) with only log warnings. Prepend http:// (the usual local-mirror
        # scheme; type https:// yourself for a TLS mirror) so a bare host still works.
        if (exists $params->{pref_mb_base_url}) {
            (my $u = $params->{pref_mb_base_url}) =~ s/^\s+|\s+$//g;
            $u = "http://$u" if length $u && $u !~ m{^https?://}i;
            $params->{pref_mb_base_url} = $u;
        }

        # Unblock any artists whose "remove" box was ticked. blocked_artists is
        # not in the prefs() list (it's a structured arrayref, not a scalar pref),
        # so we mutate it here directly; SUPER::handler leaves it untouched. The
        # checkbox name carries the entry's list index (lbf_unblock_<i>).
        my $blocked = $prefs->get('blocked_artists');
        if (ref $blocked eq 'ARRAY' && @$blocked) {
            my @kept;
            for my $i (0 .. $#$blocked) {
                push @kept, $blocked->[$i] unless $params->{"lbf_unblock_$i"};
            }
            $prefs->set('blocked_artists', \@kept) if @kept != @$blocked;
        }

        $log->info('ListenBrainz Fresh Releases settings saved');

        # Validate the token against ListenBrainz and report the result on the
        # page. This is async, so render only once the check (or its failure /
        # timeout) returns; until then the handler defers via $callback. The
        # posted token is what we validate (independent of the pref save, which
        # SUPER::handler does when we render below).
        my $token = $params->{pref_token};
        if (defined $token && length $token) {
            require Plugins::ListenBrainzFreshReleases::API;
            Plugins::ListenBrainzFreshReleases::API->validateToken(
                $token,
                sub {
                    $params->{warning} = _tokenMessage(shift);
                    $callback->($client, $params, $class->_render($client, $params), @args);
                },
                sub {
                    my $err = shift;
                    $log->warn("token validation failed: " . ($err // '?'));
                    $params->{warning} = string('PLUGIN_LBF_TOKEN_CHECK_FAILED');
                    $callback->($client, $params, $class->_render($client, $params), @args);
                },
            );
            return;   # async: _render is delivered through $callback above
        }
    }

    return $class->_render($client, $params);
}

# Render the settings page via the base handler (which persists the prefs and
# builds the page). Shared by the sync and async (token-validated) paths.
sub _render {
    my ($class, $client, $params) = @_;
    return $class->SUPER::handler($client, $params);
}

# Slim::Web::Settings::handler persists the POST, refreshes its own `prefs`
# template var from the store, and THEN calls this — the last hook before the
# template renders.
#
# ANY template variable derived from a pref MUST be built here, not before
# SUPER::handler. `lbf_services` carries each service's CURRENT priority; built
# in _render() it was read BEFORE the save, so saving a new priority re-rendered
# the page with the old number still in the input (the save had actually applied
# — a reload showed it). Fixed 0.9.85.
sub beforeRender {
    my ($class, $params, $client) = @_;

    require Plugins::ListenBrainzFreshReleases::Browse;
    $params->{lbf_services} = Plugins::ListenBrainzFreshReleases::Browse::serviceStatus();

    # The blocked-artists list (with each entry's index, for the unblock checkbox).
    # handler() mutates blocked_artists directly (it's a structured arrayref, not
    # in the prefs() list), so reading it here also picks up this save's unblocks.
    my $blocked = $prefs->get('blocked_artists');
    $blocked = [] unless ref $blocked eq 'ARRAY';
    $params->{lbf_blocked} = [
        map {{ idx => $_, name => ($blocked->[$_]{name} // ''), mbid => ($blocked->[$_]{mbid} // '') }}
        grep { ref $blocked->[$_] eq 'HASH' } 0 .. $#$blocked
    ];
}

# Turn a /1/validate-token response into a user-facing message. ListenBrainz
# returns { valid => true/false, user_name => '...' }.
sub _tokenMessage {
    my ($data) = @_;
    unless (ref $data eq 'HASH' && $data->{valid}) {
        return string('PLUGIN_LBF_TOKEN_INVALID');
    }
    my $user = $data->{user_name} // $data->{user} // '';
    return length $user
        ? sprintf(string('PLUGIN_LBF_TOKEN_VALID_USER'), $user)
        : string('PLUGIN_LBF_TOKEN_VALID');
}

1;

__END__
