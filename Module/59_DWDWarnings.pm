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
# v1. Beta 1 - 20160429
# v1. Beta 2 - 20160502
# v1. Beta 3 - 20160607
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
use POSIX qw( strftime );
use Try::Tiny;


##############################################################################


sub DWDWarnings_Initialize($) {
	my ($hash) = @_;
	my $name = $hash->{NAME};

	$hash->{DefFn}		=	"DWDWarnings_Define";
	$hash->{UndefFn}	=	"DWDWarnings_Undefine";
	$hash->{GetFn}		=	"DWDWarnings_Get";
	$hash->{AttrList}	=	"disable:0,1 ".
								"INTERVAL ".
								$readingFnAttributes;
}

sub DWDWarnings_Define($$$) {
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def);
	my ($found, $dummy);

	return "syntax: define <name> DWDWarnings <warningID>" if(int(@a) != 3 );
	my $name = $hash->{NAME};

	$hash->{helper}{warningID}	= $a[2];
	$hash->{helper}{INTERVAL} 	= 300;

	$hash->{STATE} 			= "Initialized";
	$hash->{INTERVAL}       = 3600;
	
	RemoveInternalTimer($hash);
	 #Get first data after 32 seconds
   InternalTimer( gettimeofday() + 32, "DWDWarnings_GetUpdate", $hash, 0 );
	return undef;
}

sub DWDWarnings_Undefine($$) {
	my ($hash, $arg) = @_;
	my $name = $hash->{NAME};
	RemoveInternalTimer($hash);
	fhem("deletereading $name *", 1);
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
	
	$hash->{INTERVAL} = AttrVal( $name, "INTERVAL",  $hash->{INTERVAL} );
	
	if($hash->{INTERVAL} > 0) {
		# reset timer if interval is defined
		RemoveInternalTimer( $hash );
		InternalTimer(gettimeofday() + $hash->{INTERVAL}, "DWDWarnings_GetUpdate", $hash, 1 );
		return undef if AttrVal($name, "disable", 0 ) == 1 && !$hash->{fhem}{LOCAL};
   }
   
   # "Set update"-action will kill a running update child process
   if (defined ($hash->{helper}{RUNNING_PID}) && $hash->{fhem}{LOCAL})
   {
      BlockingKill($hash->{helper}{RUNNING_PID});
      delete( $hash->{helper}{RUNNING_PID} );
      Log3 $name, 3, "Killing old forked process";
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

#####################################
sub DWDWarnings_Aborted($)
{
   my ($hash) = @_;
   delete( $hash->{helper}{RUNNING_PID} );
   PROPLANTA_Log $hash, 4, "Forked process timed out";
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
	
	try {
		##warnWetter.loadWarnings( am Start entfernen
		$json = substr($json,24,length($json));
		## ); am Ende entfernen
		$json = substr($json,0,(length($json)-2));
			
		$json = decode_json($json);
		
		Log3 $name, 3, "LastUpdate:  ".$json->{time};
		
		my $lastUpdateTime = $json->{time};
		
		fhem( "deletereading $name warning.*", 1 );
		fhem( "deletereading $name vorabInformation.*", 1 );
		
		# Start update readings
		readingsBeginUpdate($hash); 
		readingsBulkUpdate($hash, "lastUpdateUX", ($lastUpdateTime));
		readingsBulkUpdate($hash, "lastUpdate",DWDWarnings_makeTimeString($lastUpdateTime));
		
		my $warningID = $hash->{helper}{warningID};
		my $warningText     = "";
		my $headLines = "";
		
		if (exists $json->{vorabInformation}->{$warningID})
		{
			my $station = $json->{vorabInformation}->{$warningID};
			my $warningsCount = scalar (@{$station});
			readingsBulkUpdate($hash, "vorabInformationCount", $warningsCount);
					
			my $count           = 1;
			my $highestLevel    = 0;
			my $highestMsg		= "";
			
			foreach my $item( @$station )
			{
				my $infoHeadLine 	= "vorabInformation".$count."HeadLine";
				my $infoRegion		= "vorabInformation".$count."Region";
				my $infoDesc		= "vorabInformation".$count."Desc";
				my $infoStart		= "vorabInformation".$count."validFrom";
				my $infoEnd			= "vorabInformation".$count."validTo";
				my $infoLevel		= "vorabInformation".$count."level";

				readingsBulkUpdate($hash, $infoHeadLine,	Encode::encode("UTF-8",$item->{'headline'}));
				readingsBulkUpdate($hash, $infoRegion,		Encode::encode("UTF-8",$item->{'regionName'}));
				readingsBulkUpdate($hash, $infoDesc,		Encode::encode("UTF-8",$item->{'description'}));
				readingsBulkUpdate($hash, $infoStart, 		DWDWarnings_makeTimeString($item->{'start'}));
				readingsBulkUpdate($hash, $infoEnd, 		DWDWarnings_makeTimeString($item->{'end'}));
				readingsBulkUpdate($hash, $infoLevel, 		$item->{'level'});
				$count++;
				
				if ($item->{'level'} >  $highestLevel)
				{
					$highestLevel = $item->{'level'};
					$highestMsg = Encode::encode("UTF-8",$item->{'headline'});
				}
				
				$headLines = $headLines.Encode::encode("UTF-8",$item->{'headline'})."<br>";
				$warningText = $warningText."<b>".$item->{'headline'}." für ".$item->{'regionName'}."</b><br>Von: ".DWDWarnings_makeTimeString($item->{'start'})." bis: ".DWDWarnings_makeTimeString($item->{'end'})."<br>".$item->{'description'}."<br>";
			}
			readingsBulkUpdate($hash, "warningTextHTML",		Encode::encode("UTF-8",$warningText));
			readingsBulkUpdate($hash, "highestInfoLevel",$highestLevel);
			readingsBulkUpdate($hash, "highestInfoMsg",$highestMsg);
			readingsBulkUpdate($hash, "headLines",$headLines);			
		}
		if (exists $json->{warnings}->{$warningID})
		{
			my $station = $json->{warnings}->{$warningID};
			my $warningsCount = scalar (@{$station});
			readingsBulkUpdate($hash, "warningsCount", $warningsCount);
			
			my $count           = 1;
			my $highestLevel    = 0;
			my $highestMsg		= "";

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
				readingsBulkUpdate($hash, $warnLevel, 		$item->{'level'});
				$count++;
				
				if ($item->{'level'} >  $highestLevel)
				{
					$highestLevel = $item->{'level'};
					$highestMsg = Encode::encode("UTF-8",$item->{'headline'});
				}
				
				$headLines = $headLines.Encode::encode("UTF-8",$item->{'headline'})."<br>";
				$warningText = $warningText."<b>".$item->{'headline'}." für ".$item->{'regionName'}."</b><br>Von: ".DWDWarnings_makeTimeString($item->{'start'})." bis: ".DWDWarnings_makeTimeString($item->{'end'})."<br>".$item->{'description'}."<br>";
			}
			readingsBulkUpdate($hash, "warningTextHTML",		Encode::encode("UTF-8",$warningText));
			readingsBulkUpdate($hash, "highestLevel",$highestLevel);
			readingsBulkUpdate($hash, "highestMsg",$highestMsg);
			readingsBulkUpdate($hash, "headLines",$headLines);
		}
		else
		{
			readingsBulkUpdate($hash, "warningsCount", "0");
			readingsBulkUpdate($hash, "vorabInformation", "0");
			readingsBulkUpdate($hash, "highestLevel", "0");
			
			readingsBulkUpdate($hash, "highestMsg", "&nbsp;");
			readingsBulkUpdate($hash, "headLines", "&nbsp;");
		}
		readingsEndUpdate($hash, 1);
	}
	catch {
		Log3 $name, 2, "WARNING! Something is wrong with the JSON content: $json";
	};

	$hash->{UPDATED} = FmtDateTime(time());

	my $nextupdate = gettimeofday()+$hash->{helper}{INTERVAL};
	InternalTimer($nextupdate, "DWDWarnings_GetUpdate", $hash, 1);

	return undef;
}

sub DWDWarnings_makeTimeString($) {
	my ($time) = @_;
	
	Log3 "DWDWarnings_makeTimeString",2, "InputTime:'$time'";
	
	my $lastUpdateTime = $time/1000;
	Log3 "DWDWarnings_makeTimeString", 2,"InputTime2:'$lastUpdateTime'";
	my $dt = strftime("%d.%m.%Y %H:%M", localtime($lastUpdateTime));
	Log3 "DWDWarnings_makeTimeString", 2,"dt:'$dt'";
	return $dt;
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
		<li><code>INTERVAL &lt;Abfrageinterval&gt;</code>
			<br>
			Abfrageinterval in Sekunden (Standard 300 = 5 Minuten)
      </li><br>
  </ul>
</ul>

=end html_DE
=cut
