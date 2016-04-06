##############################################
# 
#
#  59_DWDWarnings.pm
#
#  2016 Niels Hetzke < vorname at nachname . net >
#
#  This module provides DWDWarnings data
#
#  
# v1. Beta 1 - 20160406
#
##############################################################################
#
# define <name> DWDWarnings <warningID>
#
##############################################################################

package main;

use strict;
use warnings;
use Time::Local;
use Encode;
use LWP::UserAgent;
use HTTP::Request;
use utf8;
use JSON qw(decode_json);
use locale;
use POSIX 'locale_h';
setlocale(LC_ALL, 'de_DE.UTF-8');

##############################################################################


sub DWDWarnings_Initialize($) {
	my ($hash) = @_;
	my $name = $hash->{NAME};

	$hash->{DefFn}		=	"DWDWarnings_Define";
	$hash->{UndefFn}	=	"DWDWarnings_Undefine";
	$hash->{GetFn}		=	"DWDWarnings_Get";
	$hash->{AttrList}	=	"disable:0,1 ".
								"ignoreList ".
								"updateIgnored:1 ".
								"updateEmpty:1 ".
								"levelsFormat ".
								"weekdaysFormat ".
								$readingFnAttributes;
}

sub DWDWarnings_Define($$$) {
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def);
	my ($found, $dummy);

	return "syntax: define <name> DWDWarnings <warningID>" if(int(@a) != 3 );
	my $name = $hash->{NAME};

	$hash->{helper}{warningID} = $a[2];
	$hash->{helper}{INTERVAL} = 300;

	$hash->{STATE} = "Initialized";
	return undef;
}

sub DWDWarnings_Undefine($$) {
	my ($hash, $arg) = @_;
	my $name = $hash->{NAME};
	RemoveInternalTimer($hash);
	fhem("deletereading $name fc.*", 1);
	return undef;
}


sub DWDWarnings_Get($@) {
	my ($hash, @a) = @_;
	my $command = $a[1];
	my $parameter = $a[2] if(defined($a[2]));
	my $name = $hash->{NAME};
	my $usage = "Unknown argument $command, choose one of data:noArg ";

	return $usage if $command eq '?';

	RemoveInternalTimer($hash);

	if(AttrVal($name, "disable", 0) eq 1) {
		$hash->{STATE} = "disabled";
		return "DWDWarnings $name is disabled. Aborting...";
	}

	DWDWarnings_GetUpdate($hash);
	return undef;
}


sub DWDWarnings_GetUpdate($) {
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if(AttrVal($name, "disable", 0) eq 1) {
		$hash->{STATE} = "disabled";
		Log3 $name, 2, "DWDWarnings $name is disabled, data update cancelled.";
		return undef;
	}

	my $url="http://www.dwd.de/DWD/warnungen/warnapp/json/warnings.json";
	Log3 $name, 3, "Getting URL $url";

	HttpUtils_NonblockingGet({
		url => $url,
		noshutdown => 1,
		hash => $hash,
		type => 'DWDWarningsdata',
		callback => \&DWDWarnings_Parse,
	});
	return undef;
}


sub DWDWarnings_Parse($$$)
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	my $name = $hash->{NAME};

	if( $err )
	{
		Log3 $name, 1, "$name: URL error: ".$err;
		$hash->{STATE} = "error";
		return undef;
	}

	my $json = $data;
	
	##warnWetter.loadWarnings( am Start entfernen
	$json = substr($json,24,length($json));
	## ); am Ende entfernen
	$json = substr($json,0,(length($json)-2));
		
	$json = decode_json($json);
	
	Log3 $name, 3, "LastUpdate:  ".$json->{time};
	
	my $lastUpdateTime = ($json->{time}/1000);
	
	fhem( "deletereading $name warning.*", 1 );
	
	readingsBeginUpdate($hash); # Start update readings
	readingsBulkUpdate($hash, "lastUpdateUX", ($json->{time}));
	readingsBulkUpdate($hash, "lastUpdate",DWDWarnings_makeTimeString($lastUpdateTime));
	
	my $warningID = $hash->{helper}{warningID};
	
	if (exists $json->{warnings}->{$warningID})
	{
		my $station = $json->{warnings}->{$warningID};
		my $warningsCount = scalar (@{$station});
		readingsBulkUpdate($hash, "warningsCount", $warningsCount);
	
		my $warningText = "";
		my $count = 1;
		foreach my $item( @$station )
		{
			my $warnHeadLine 	= "warning".$count."HeadLine";
			my $warnRegion		= "warning".$count."Region";
			my $warnDesc		= "warning".$count."Desc";
			my $warnStart		= "warning".$count."validFrom";
			my $warnEnd			= "warning".$count."validTo";
			my $warnLevel		= "warning".$count."level";

			readingsBulkUpdate($hash, $warnHeadLine,	Encode::encode("UTF-8",$item->{'headline'}));
			readingsBulkUpdate($hash, $warnRegion,		Encode::encode("UTF-8",$item->{'regionName'}));
			readingsBulkUpdate($hash, $warnDesc,		Encode::encode("UTF-8",$item->{'description'}));
			readingsBulkUpdate($hash, $warnStart, 		DWDWarnings_makeTimeString($item->{'start'}));
			readingsBulkUpdate($hash, $warnEnd, 		DWDWarnings_makeTimeString($item->{'end'}));
			readingsBulkUpdate($hash, $warnLevel, 		DWDWarnings_makeTimeString($item->{'level'}));
			$count++;

			$warningText = $warningText."<b>".$item->{'headline'}." für ".$item->{'regionName'}."</b><br>Von: ".DWDWarnings_makeTimeString($item->{'start'})." bis: ".DWDWarnings_makeTimeString($item->{'end'})."<br>".$item->{'description'}."<br>";
		}
		readingsBulkUpdate($hash, "warningTextHTML",		Encode::encode("UTF-8",$warningText));
	}
	else
	{
		readingsBulkUpdate($hash, "warningsCount", "0");
	}
	readingsEndUpdate($hash, 1);

	$hash->{UPDATED} = FmtDateTime(time());

	my $nextupdate = gettimeofday()+$hash->{helper}{INTERVAL};
	InternalTimer($nextupdate, "DWDWarnings_GetUpdate", $hash, 1);

	return undef;
}

sub DWDWarnings_makeTimeString($) {
	my ($time) = @_;
	
	my $lastUpdateTime = $time/1000;
	my ($sec,$min,$hour,$day,$month,$year) = (localtime $lastUpdateTime)[0..5];
   	$month = $month +1; 
	$year = $year+1900;
	
	return "$day.$month.$year $hour:$min";
}
##########################

1;

=pod
=begin html

<a name="DWDWarnings"></a>
<h3>DWDWarnings</h3>
<ul>
  This modul provides DWDWarnings data for Germany.<br/>
  <br/><br/>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; DWDWarnings &lt;warningID&gt;</code>
    <br>
    Example: <code>define DWDWarningsdata DWDWarnings 12345</code>
    <br>&nbsp;
    <li><code>warningID</code>
      <br>
      warningID
    </li><br>
  </ul>
  <br>
  <b>Get</b>
   <ul>
      <li><code>data</code>
      <br>
      Manually trigger data update
      </li><br>
  </ul>
  <br>
  <b>Readings</b>
   <ul>
      <li><code>lastUpdate</code>
		  <br>
		  Time of last update 
      </li><br>
	  <li><code>lastUpdateUX</code>
		  <br>
		  Time of last update as Unix timestamp
      </li><br>
      <li><code>warningsCount</code>
		  <br>
		  Numbers of warnings for warning rgion 
      </li><br>
  </ul>
  <br>
   <b>Attributes</b>
   <ul>
      <li><code>ignoreList</code>
         <br>
         Comma-separated list of allergen names that are to be ignored during updates and for cumulated day levels calculation
      </li><br>
      <li><code>updateEmpty</code>
         <br>
         Also update (and keep) level readings for inactive allergens that are otherwise removed
      </li><br>
      <li><code>updateIgnored</code>
         <br>
         Also update (and keep) level readings for ignored allergens that are otherwise removed
      </li><br>
      <li><code>levelsFormat</code>
         <br>
         Localize levels by adding them comma separated (default: -,low,moderate,high,extreme)
      </li><br>
      <li><code>weekdaysFormat</code>
         <br>
         Localize Weekdays by adding them comma separated (default: Sun,Mon,Tue,Wed,Thu,Fr,Sat)
      </li><br>
  </ul>
</ul>

=end html
=begin html_DE

<a name="DWDWarnings"></a>
<h3>DWDWarnings</h3>
<ul>
  <br>Dieses Modul holt die Wetterwarnung vom DWD.</br>
  <br/><br/>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; DWDWarnings &lt;warningID&gt;</code>
    <br>
    Beispiel: <code>define DWDWarningsdata DWDWarnings 12345</code>
    <br><br>
    <li><code>warningID</code>
      <br>
      Warnungs ID / Region.
    </li><br>
  </ul>
  <br>
  <b>Get</b>
   <ul>
      <li><code>data</code>
      <br>
      Manuelles Datenupdate
      </li><br>
  </ul>
  <br>
  <b>Readings</b>
   <ul>
      <li><code>lastUpdate</code>
		  <br>
		  Letzte Zeit des Updates innerhalb der Datenlieferung
      </li><br>
	  <li><code>lastUpdateUX</code>
		  <br>
		  Letzte Zeit des Updates innerhalb der Datenlieferung, als Unix Timestamp
      </li><br>
      <li><code>warningsCount</code>
		  <br>
		  Anzahl von Warnungen für die Warnregion
      </li><br>
  </ul>
  <br>
   <b>Attribute</b>
   <ul>
      <li><code>ignoreList</code>
         <br>
         Kommagetrennte Liste von Allergen-Namen, die bei der Aktualisierung ignoriert werden sollen.
    <br>
      </li><br>
      <li><code>updateEmpty (Standard: 0|1)</code>
         <br>
         Aktualisierung von Allergenen.
    <code> <br>
    0 = nur Allergene mit Belastung.
    <br>
    1 = auch Allergene die keine Belastung haben.
    </code>
      </li><br>
      <li><code>updateIgnored (1)</code>
         <br>
         Aktualisierung von Allergenen, die sonst durch die ignoreList entfernt werden.
      </li><br>
      <li><code>levelsFormat (Standard: -,low,moderate,high,extreme)</code>
         <br>
         Lokalisierte Levels, durch Kommas getrennt.
      </li><br>
      <li><code>weekdaysFormat (Standard: Sun,Mon,Tue,Wed,Thu,Fri,Sat)</code>
         <br>
         Lokalisierte Wochentage, durch Kommas getrennt.
      </li><br>
  </ul>
</ul>

=end html_DE
=cut
