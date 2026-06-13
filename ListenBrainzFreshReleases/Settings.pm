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
    return ($prefs, qw(username token days sort past future));
}

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    if ($params->{saveSettings}) {
        my $days = $params->{pref_days} // 14;
        $days = 14 unless $days =~ /^\d+$/;
        $days = 1  if $days < 1;
        $days = 90 if $days > 90;
        $prefs->set('days', $days + 0);
        $log->info('ListenBrainz Fresh Releases settings saved');
    }

    return $class->SUPER::handler($client, $params);
}

1;

__END__
