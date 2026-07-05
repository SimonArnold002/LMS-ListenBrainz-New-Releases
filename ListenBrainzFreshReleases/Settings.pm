package Plugins::ListenBrainzFreshReleases::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

my $prefs = preferences('plugin.listenbrainzfreshreleases');
my $log   = logger('plugin.listenbrainzfreshreleases');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_LISTENBRAINZ_FRESH_RELEASES');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/ListenBrainzFreshReleases/settings.html');
}

sub prefs {
    return ($prefs, qw(
        username token lastfm_api_key days sort group_by_artist week_dividers play_via prefer_library debug_log
        svc_priority_qobuz svc_priority_bandcamp svc_priority_tidal
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
        for my $svc (qw(qobuz bandcamp tidal)) {
            my $p = $params->{"pref_svc_priority_$svc"};
            if (defined $p && $p =~ /^\d+$/) {
                $p = 9 if $p > 9;
                $params->{"pref_svc_priority_$svc"} = $p + 0;
            }
            else {
                $params->{"pref_svc_priority_$svc"} = $prefs->get("svc_priority_$svc") // 0;
            }
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

# Render the settings page: expose the detected streaming services to the
# template, then hand off to the base handler (which persists the prefs and
# builds the page). Shared by the sync and async (token-validated) paths.
sub _render {
    my ($class, $client, $params) = @_;
    require Plugins::ListenBrainzFreshReleases::Browse;
    $params->{lbf_services} = Plugins::ListenBrainzFreshReleases::Browse::serviceStatus();

    # The blocked-artists list (with each entry's index, for the unblock checkbox).
    my $blocked = $prefs->get('blocked_artists');
    $blocked = [] unless ref $blocked eq 'ARRAY';
    $params->{lbf_blocked} = [
        map {{ idx => $_, name => ($blocked->[$_]{name} // ''), mbid => ($blocked->[$_]{mbid} // '') }}
        grep { ref $blocked->[$_] eq 'HASH' } 0 .. $#$blocked
    ];

    return $class->SUPER::handler($client, $params);
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
