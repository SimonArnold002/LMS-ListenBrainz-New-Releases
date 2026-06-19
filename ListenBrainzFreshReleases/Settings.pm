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
        username token lastfm_api_key days sort group_by_artist week_dividers play_via prefer_library
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
        my $days = $params->{pref_days} // 14;
        $days = 14 unless $days =~ /^\d+$/;
        $days = 1  if $days < 1;
        $days = 90 if $days > 90;
        $prefs->set('days', $days + 0);

        # Normalise the service priorities to integers 0-9 (0 = never search).
        for my $svc (qw(qobuz bandcamp tidal)) {
            my $p = $params->{"pref_svc_priority_$svc"};
            $p = 0 unless defined $p && $p =~ /^\d+$/;
            $p = 9 if $p > 9;
            $prefs->set("svc_priority_$svc", $p + 0);
        }

        $log->info('ListenBrainz Fresh Releases settings saved');
    }

    # Expose detected streaming services (+ their priority) to the template.
    require Plugins::ListenBrainzFreshReleases::Browse;
    $params->{lbf_services} = Plugins::ListenBrainzFreshReleases::Browse::serviceStatus();

    return $class->SUPER::handler($client, $params);
}

1;

__END__
