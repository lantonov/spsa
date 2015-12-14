#!/usr/bin/perl

# SPSA Tuner
# Copyright (C) 2009-2014 Joona Kiiski
#
# SPSA Tuner is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# SPSA Tuner is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;

use threads;
use threads::shared;
use Time::HiRes qw(time);
use IPC::Open2;
use IO::Select;
use Config::Tiny;
use Text::CSV;
use Math::Round qw(nearest nearest_floor);
use List::Util qw(min max);
use IO::Handle;
use AutoLoader qw(AUTOLOAD);

STDOUT->autoflush(1);
STDERR->autoflush(1);

my $IS_WINDOWS = ($^O eq 'MSWin32');

### SECTION. Settings (Static data during execution)

my $ConfigFile = $ARGV[0] || die "You must pass the name of config file as parameter!";
my $Config = Config::Tiny->new;
$Config = Config::Tiny->read($ConfigFile) || die "Unable to read configuration file '" . $ConfigFile . "'";

my $simulate       = $Config->{Main}->{Simulate}  ; defined($simulate)       || die "Simulate not defined!";
my $zero_start     = $Config->{Main}->{ZeroStart} ; defined($zero_start)     || die "Zero start not defined!";
my $variables_path = $Config->{Main}->{Variables} ; defined($variables_path) || die "Variables not defined!";
my $log_path       = $Config->{Main}->{Log}       ; defined($log_path)       || die "Log not defined!";;
my $gamelog_path   = $Config->{Main}->{GameLog}   ; defined($gamelog_path)   || die "GameLog not defined!";;
my $iterations     = $Config->{Main}->{Iterations}; defined($iterations)     || die "Iterations not defined!";;

my $eng1_path        = $Config->{Engine}->{Engine1}        ; defined($eng1_path)        || $simulate || die "Engine1 not defined!";
my $eng2_path        = $Config->{Engine}->{Engine2}        ; defined($eng2_path)        || $simulate || die "Engine2 not defined!";
my $epd_path         = $Config->{Engine}->{EPDBook}        ; defined($epd_path)         || $simulate || die "EPDBook not defined!";
my $base_time        = $Config->{Engine}->{BaseTime}       ; defined($base_time)        || $simulate || die "BaseTime not defined!";
my $inc_time         = $Config->{Engine}->{IncTime}        ; defined($inc_time)         || $simulate || die "IncTime not defined!";
my $threads          = $Config->{Engine}->{Concurrency}    ; defined($threads)          || $simulate || die "Concurrency not defined!";
my $draw_score_limit = $Config->{Engine}->{DrawScoreLimit} ; defined($draw_score_limit) || $simulate || die "DrawScoreLimit not defined!";
my $draw_move_limit  = $Config->{Engine}->{DrawMoveLimit}  ; defined($draw_move_limit)  || $simulate || die "DrawMoveLimit not defined!";
my $win_score_limit  = $Config->{Engine}->{WinScoreLimit}  ; defined($win_score_limit)  || $simulate || die "WinScoreLimit not defined!";
my $win_move_limit   = $Config->{Engine}->{WinMoveLimit}   ; defined($win_move_limit)   || $simulate || die "WinMoveLimit not defined!";

$threads = 1 if ($simulate);

### SECTION. Variable CSV-file columns. (Static data during execution)
my $VAR_NAME      = 0; # Name
my $VAR_START     = 1; # Start Value (theta_0)
my $VAR_MIN       = 2; # Minimum allowed value
my $VAR_MAX       = 3; # Maximum allowed value
my $VAR_C_END     = 4; # c in the last iteration
my $VAR_ZERO     = 5; # R in the last iteration. R = a / c ^ 2.
my $VAR_SIMUL_ELO = 6; # Simulation: Elo loss from 0 (optimum) to +-100)
my $VAR_END       = 7; # Nothing

### SECTION. Variable definitions. (Static data during execution)
my @variables;
my %variableIdx;

### SECTION. Log file handle (Static data during execution)
local (*LOG);

### SECTION. Shared data (volatile data during the execution)
my $shared_lock      :shared;
my $shared_iter      :shared; # Iteration counter
my %shared_theta     :shared; # Current values by variable name
my %var_eng2         :shared;
my %var_eng1plus     :shared;
my %var_eng1minus    :shared;

### SECTION. Helper functions

# Function to safely read in a standard CSV-file.
sub read_csv
{
    my ($csvfile, $rows) = @_;
    my ($CSV, $row);

    open(INFILE, '<', $csvfile) || die "Could not open file '$csvfile' for reading!";
    binmode(INFILE);

    $CSV = Text::CSV->new();
    while($row = $CSV->getline(\*INFILE))
    {
        push(@$rows, $row);
    }

    $CSV->eof || die "CSV-file parsing error: " . $CSV->error_diag();
    close(INFILE);
}

### SECTION. Execution preparation code ("main" function)
{
    my $row;

    # STEP. Open shared log file.
    open(LOG, '>', $log_path) || die "Could not open file '$log_path' for writing!";
    LOG->autoflush(1);

    # STEP. Read in variable data.
    read_csv($variables_path, \@variables);

    # STEP. Validate variable data.
    foreach $row (@variables)
    {
        die "Wrong number of columns!" if (scalar(@$row) != $VAR_END);

        die "Invalid name: '$row->[$VAR_NAME]'"               if ($row->[$VAR_NAME]      !~ /^\w+$/);
        die "Invalid current: '$row->[$VAR_START]'"           if ($row->[$VAR_START]     !~ /^[-+]?[0-9]*\.?[0-9]+$/);
        die "Invalid max: '$row->[$VAR_MAX]'"                 if ($row->[$VAR_MAX]       !~ /^[-+]?[0-9]*\.?[0-9]+$/);
        die "Invalid min: '$row->[$VAR_MIN]'"                 if ($row->[$VAR_MIN]       !~ /^[-+]?[0-9]*\.?[0-9]+$/);
        die "Invalid c end: '$row->[$VAR_C_END]'"             if ($row->[$VAR_C_END]     !~ /^[-+]?[0-9]*\.?[0-9]+$/);
        die "Invalid r end: '$row->[$VAR_ZERO]'"             if ($row->[$VAR_ZERO]     !~ /^[-+]?[0-9]*\.?[0-9]+$/);
        die "Invalid simul ELO: '$row->[$VAR_SIMUL_ELO]'"     if ($row->[$VAR_SIMUL_ELO] !~ /^[-+]?[0-9]*\.?[0-9]+$/);
    }
    
    # STEP. Create variable index for easy access.
    foreach $row (@variables)
    {
        $variableIdx{$row->[$VAR_NAME]} = $row;
    }

    # STEP. Prepare shared data
    $shared_iter = 0;
    
    foreach $row (@variables)
    {
        $shared_theta{$row->[$VAR_NAME]} = $zero_start == 0 ? $row->[$VAR_START] : $row->[$VAR_ZERO];
        $var_eng2{$row->[$VAR_NAME]} = $zero_start == 0 ? $row->[$VAR_START] : $row->[$VAR_ZERO];;
#        $var_eng0{$row->[$VAR_NAME]} = 0;
    }

	# Start from zero or from initial values
#	%shared_theta = $zero_start == 0 ? %shared_theta : %var_eng0;

    # STEP. Launch SPSA threads
    my @thr;

    for (my $i = 1; $i <= $threads; $i++)
    {
        $thr[$i] = threads->create(\&run_spsa, $i);

        # HACK: Under Windows the combination of starting new threads and 
        # calling open2() at the same time seems to be problematic.
        # So wait for 3 seconds to make sure each new thread has cleanly 
        # started the engine process before starting a new thread.
        sleep(3) if $IS_WINDOWS;
    }

    # STEP. Join threads
    for (my $i = 1; $i <= $threads; $i++)
    {
        $thr[$i]->join();
    }

    # STEP. Close Log file
    close(LOG);

    # STEP. Quit
    exit 0;
}

### SECTION. SPSA
local (*GAMELOG);

sub run_spsa
{
    my ($threadId) = @_;
    my $row;
    my $result_inc_plus = 0;
    my $result_inc_minus = 0;
	my $cost = 0.5;

	# STEP. Calculate number of variables
	my $n_variables = scalar(@variables);# print "$n_variables \n";

	# STEP. Calculate sum and mean of absolute variable values.
	my $sum_var;
             foreach $row (@variables)
             {
              my $name  = $row->[$VAR_NAME];
              $sum_var += abs($var_eng2{$name});
             }

	my $mean = $sum_var / $n_variables; print "$mean \n";

    # STEP. Open thread specific log file
    my $path = $gamelog_path;
    my $from = quotemeta('$THREAD');
    my $to = $threadId;
    $path =~ s/$from/$to/g;

    open(GAMELOG, '>', $path) || die "Could not open file '$path' for writing!";;

    # STEP. Init random generator
    srand(time ^ $$ ^ $threadId);

    # STEP. Init engines
    engine_init() if (!$simulate);

    while(1)
    {
        # SPSA coefficients indexed by variable.
        my (%var_value, %var_min, %var_max, %var_delta);
        my ($iter, $var_a, $var_c); 

        {
             lock($shared_lock);

             # STEP. Increase the shared interation counter
             if (++$shared_iter > $iterations || $cost < 1/11)
             {
                 engine_quit() if (!$simulate);
                 return;
             }

             $iter = $shared_iter;

             # STEP. Calculate the necessary coefficients for each variable.
        $var_a  = 10 * ($cost) ** 2 / (1 + 10 ** ((1+$iter) / $iterations));
#        $var_c  = $mean * $cost;
        $var_c  = 10 * $var_a;

             foreach $row (@variables)
             {
                 my $name  = $row->[$VAR_NAME];
                 $var_value{$name}  = $shared_theta{$name};
                 $var_min{$name}    = $row->[$VAR_MIN];
                 $var_max{$name}    = $row->[$VAR_MAX];
                 $var_delta{$name}  = int(rand(2)) ? 1 : -1;

                 $var_eng1plus{$name} = min(max($var_value{$name} + $var_c * $var_delta{$name}, $var_min{$name}), $var_max{$name});
                 $var_eng1minus{$name} = min(max($var_value{$name} - $var_c * $var_delta{$name}, $var_min{$name}), $var_max{$name});

		print "Iteration: $iter, variable: $name, value: $var_value{$name}, a: $var_a, c: $var_c, Cost: $cost \n";
             }
        }

        # STEP. Play two games (with alternating colors) and obtain the result (2, 1, 0, -1, -2) from eng1 perspective.
        my $result_inc = 0;
		for (my $i=0;$i<10;$i++) {

		my $result_plus = ($simulate ? simulate_2games(\%var_eng1plus,\%var_eng2) : engine_2games(\%var_eng1plus,\%var_eng2));# print $result_plus;
        $result_inc_plus += $result_plus;

        my $result_minus = ($simulate ? simulate_2games(\%var_eng1minus,\%var_eng2) : engine_2games(\%var_eng1minus,\%var_eng2));# print $result_minus;
        $result_inc_minus += $result_minus;

		$result_inc += $result_plus - $result_minus; print $result_inc;
          }

        $cost = 1 / (1 + 10 ** (max($result_inc_plus + $result_inc_minus,-40) / 400));

        # STEP. Apply the result
        {
            lock($shared_lock);

            my $logLine = "$iter, $var_a, $cost \n";
			my $logLine1;

            foreach $row (@variables)
            {
                my $name = $row->[$VAR_NAME];

                $shared_theta{$name} += $result_inc != 0 ? $var_a * $result_inc / abs($result_inc) / $var_delta{$name} : 0;
                $shared_theta{$name} = max(min($shared_theta{$name}, $var_max{$name}), $var_min{$name});
                
             $logLine1 .= ",$shared_theta{$name}";
            }

            print LOG "$logLine $logLine1\n "
        }
    }

    # STEP. Close log
    close(GAMELOG);
}

### SECTION. Simulating a game

sub simulate_ELO
{
    my ($var) = @_;
    my $ELO = 0.0;

    foreach my $key (keys(%$var))
    {
        my $a = -0.0001 * $variableIdx{$key}[$VAR_SIMUL_ELO];
        $ELO += $a * $var->{$key} ** 2;
    }
   
    return $ELO; 
}

sub simulate_winPerc
{
    my ($ELO_A, $ELO_B) = @_;

    my $Q_A = 10 ** ($ELO_A / 400);
    my $Q_B = 10 ** ($ELO_B / 400);

    return $Q_A / ($Q_A + $Q_B);
}

sub simulate_2games
{
    my ($var_eng1, $var_eng2) = @_;

    my $eng1_elo = simulate_ELO($var_eng1);
    my $eng2_elo = simulate_ELO($var_eng2);

    my $eng1_winperc = simulate_winPerc($eng1_elo, $eng2_elo);

    return (rand() < $eng1_winperc ? 1 : -1) + (rand() < $eng1_winperc ? 1 : -1);
}

### SECTION. Playing a game

my @fenlines;

my ($eng1_pid, $eng2_pid);
local (*Eng1_Reader, *Eng1_Writer);
local (*Eng2_Reader, *Eng2_Writer);

sub engine_init
{
    # STEP. Read opening book.
    open(INPUT, "<$epd_path");
    binmode(INPUT);
    my @lines;
    (@lines) = <INPUT>;
    @fenlines = grep {/\w+/} @lines; # Filter out empty lines
    close (INPUT);
    die "epd read failure!" if ($#fenlines == -1);

    # STEP. Launch engines.
    $eng1_pid = open2(\*Eng1_Reader, \*Eng1_Writer, $eng1_path);
    $eng2_pid = open2(\*Eng2_Reader, \*Eng2_Writer, $eng2_path);

    # STEP. Init engines
    my $line;

    print Eng1_Writer "uci\n";
    print Eng2_Writer "uci\n";

    while(engine_readline(\*Eng1_Reader) ne "uciok") {} 
    while(engine_readline(\*Eng2_Reader) ne "uciok") {}
}

sub engine_quit 
{ 
    print Eng1_Writer "quit\n"; 
    print Eng2_Writer "quit\n"; 
    waitpid($eng1_pid, 0); 
    waitpid($eng2_pid, 0); 
} 

sub engine_readline
{
    my ($Reader) = @_;
    local $/ = $IS_WINDOWS ? "\r\n" : "\n";
    my $line = <$Reader>;
    chomp $line;
    return $line;
}

sub engine_2games
{
    my ($var_eng1, $var_eng2) = @_;
    my $result = 0;
    my $line;

    # STEP. Choose a random opening
    my $rand_i = int(rand($#fenlines + 1));
    my @tmparray = split(/\;/, $fenlines[$rand_i]);
    my $fenline = $tmparray[0];
    @tmparray = split(/ /, $fenline);
    my $side_to_start = $tmparray[1]; #'b' or 'w'

    # STEP. Send rounded values to engines

	foreach my $var (keys(%$var_eng2))
    {
       my $val1 = nearest(1, $var_eng1->{$var});
       my $val2 = nearest(1, $var_eng2->{$var});
        
        print Eng1_Writer "setoption name $var value $val1\n";
        print Eng2_Writer "setoption name $var value $val2\n";
    }

   
    # STEP. Play two games
    for (my $eng1_is_white = 0; $eng1_is_white < 2; $eng1_is_white++)
    {
        # STEP. Tell engines to prepare for a new game
        print Eng1_Writer "ucinewgame\n";
        print Eng2_Writer "ucinewgame\n";

        print Eng1_Writer "isready\n";
        print Eng2_Writer "isready\n";

        # STEP. Wait for engines to be ready
        while(engine_readline(\*Eng1_Reader) ne "readyok") {}
        while(engine_readline(\*Eng2_Reader) ne "readyok") {}

        # STEP. Init Thinking times
        my $eng1_time = $base_time;
        my $eng2_time = $base_time;

        # STEP. Check which engine should start?
        my $engine_to_move = ($eng1_is_white == 1 && $side_to_start eq 'w') || ($eng1_is_white == 0 && $side_to_start eq 'b') ? 1 : 2;

        print GAMELOG "Starting game using opening fen: $fenline (opening line $rand_i). Engine to start: $engine_to_move\n";

        # STEP. Init game variabless
        my $moves = '';
        my $winner = 0;
        my $draw_counter = 0;
        my @win_counter  = (0, 0, 0);

GAME:  while(1)
       {
           my $wtime = nearest_floor(1, $eng1_is_white == 1 ? $eng1_time : $eng2_time);
           my $btime = nearest_floor(1, $eng1_is_white == 0 ? $eng1_time : $eng2_time);

           my $Curr_Writer = ($engine_to_move == 1 ? \*Eng1_Writer : \*Eng2_Writer);
           my $Curr_Reader = ($engine_to_move == 1 ? \*Eng1_Reader : \*Eng2_Reader);

           # STEP. Send engine the current positionn
           print $Curr_Writer "position fen $fenline" . ($moves ne '' ? " moves $moves" : "") . "\n";

           print GAMELOG "Engine " . ($engine_to_move == 1 ? '1' : '2') . " starts thinking. Time: " .
                  sprintf("%d", $engine_to_move == 1 ? $eng1_time : $eng2_time) . " Moves: $moves \n";

           # STEP. Let it go!
           my $t0 = time;
           print $Curr_Writer "go wtime $wtime btime $btime winc $inc_time binc $inc_time\n";

           # STEP. Read output from engine until it prints the bestmove.
           my $score = 0;
           my $flag_mate = 0;
           my $flag_stalemate = 0;

READ:      while($line = engine_readline($Curr_Reader)) 
           {
               my @array = split(/ /, $line);

               # When engine is done, it prints bestmove.
               if ($#array >= 0 && $array[0] eq 'bestmove') {
                   
                   $flag_stalemate = 1 if ($array[1] eq '(none)');

                   $moves = $moves . " " . $array[1];
                   last READ;
               }

               # Check for mate in one
               if ($#array >= 9 && $array[0] eq 'info' && $array[1] eq 'depth' &&
                   $array[7] eq 'score' && $array[8] eq 'mate' && $array[9] eq '1') 
               {
                   $flag_mate = 1;
                   $winner = $engine_to_move;
               }

               # Record score
               if ($#array >= 7 && $array[0] eq 'info' && $array[1] eq 'depth' &&
                   $array[7] eq 'score') 
               {    
                   $score = $array[9] if ($array[8] eq 'cp');
                   $score = +100000   if ($array[8] eq 'mate' && $array[9] > 0);
                   $score = -100000   if ($array[8] eq 'mate' && $array[9] < 0);
               }
           }

           print GAMELOG "Score: $score\n" if defined($score);

           # STEP. Update thinking times
           my $elapsed = time - $t0;
           $eng1_time = $eng1_time - ($engine_to_move == 1 ? $elapsed * 1000 - $inc_time : 0); 
           $eng2_time = $eng2_time - ($engine_to_move == 2 ? $elapsed * 1000 - $inc_time : 0);

           # STEP. Check for mate and stalemate
           if ($flag_mate)
           {
               $winner = $engine_to_move;
               last GAME;
           }

           if ($flag_stalemate)
           {
               $winner = 0;
               last GAME;
           }

           # STEP. Update draw counter
           $draw_counter = (abs($score) <= $draw_score_limit ? $draw_counter + 1 : 0);

           print GAMELOG "Draw Counter: $draw_counter / $draw_move_limit\n" if ($draw_counter);

           if ($draw_counter >= $draw_move_limit)
           {
               $winner = 0;
               last GAME;
           }

           # STEP. Update win counters
           my $us   = $engine_to_move;
           my $them = $engine_to_move == 1 ? 2 : 1;

           $win_counter[$us]   = ($score >= +$win_score_limit ? $win_counter[$us]   + 1 : 0);
           $win_counter[$them] = ($score <= -$win_score_limit ? $win_counter[$them] + 1 : 0);
          
           print GAMELOG "Win Counter: $win_counter[$us] / $win_move_limit\n" if ($win_counter[$us]);
           print GAMELOG "Loss Counter: $win_counter[$them] / $win_move_limit\n" if ($win_counter[$them]); 
 
           if ($win_counter[$us] >= $win_move_limit)
           {
               $winner = $us;
               last GAME;
           }

           if ($win_counter[$them] >= $win_move_limit)
           {
               $winner = $them;
               last GAME;
           } 

           # STEP. Change turn
           $engine_to_move = $them;
       }

       # STEP. Record the result
       print GAMELOG "Winner: $winner\n";

       $result += ($winner == 1 ? 1 : $winner == 2 ? -1 : 0);
   }

   return $result;
}
