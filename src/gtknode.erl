%%%-------------------------------------------------------------------
%%% File    : gtk_node.erl
%%% Author  : Mats Cronqvist <qthmacr@mwux005>
%%% Description : 
%%%
%%% Created : 22 Nov 2004 by Mats Cronqvist <qthmacr@mwux005>
%%%-------------------------------------------------------------------
-module(gtknode).
-export([start/1,stop/1]).
-export([debug/0,debug/1,debug/2]).
-export([cmd/2,cmd/3]).

%%-export([recv/0]).
%%-export([glade/1,widget_get_attr/1,new_gvalue/2]).

-import(filename, [join/1,dirname/1]).

-record(st,{gtk_port=[],client_pid=[],handler_pid=[],gtk_pid=[],name=[]}).

-define(BORED, 5000).
-define(LOG(T), log(process_info(self()),T)).

%%%-------------------------------------------------------------------
%%% runs in client process
%%%-------------------------------------------------------------------
start(Name) -> 
    case whereis(Name) of
	undefined ->    
	    Self = self(),
	    Pid = spawn_link(fun() -> init(Self, Name) end),
	    receive 
		started -> Pid;
		quit -> ok
	    end;
	_ -> erlang:fault({already_started,Name})
    end.

stop(Pid) ->
    Pid ! quit.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% for debugging, run gtknode:debug and start gtknode from a shell thusly;
%%% gtknode <erlnodename> <host> gtknode_dbg <cookie> nod <erl_dist_version>
%%% E.g. bin/gtknode foo mwlx084 gtknode_dbg cki nod 11
%%% send messages to the gtknode with gtknode:debug/2, thusly;
%%% gtknode:dbg('GN_glade_init',["gladefile.glade"]).
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
debug(Cmd,Args) -> debug([{Cmd,Args}]).
debug(CmdArgs) ->
    catch debug(),
    gtknode_dbgH ! {cmd, CmdArgs},
    ok.
debug() ->
    case whereis(gtknode_dbg) of
	undefined -> spawn(fun initDBG/0);
	_ -> erlang:fault({already_started,gtknode_dbg})
    end.

initDBG() ->
    process_flag(trap_exit,true), 
    register(gtknode_dbg, self()),
    Handler = spawn_link(fun initDBGH/0),
    waiting_handshake(#st{handler_pid=Handler, name=gtknode_dbg}).    

initDBGH() ->
    register(gtknode_dbgH, self()),
    loopDBGH().

loopDBGH() ->
    receive 
	{gtknode_dbg, {signal, Sig}} ->
	    ?LOG({signal,Sig}),loopDBGH();
	{gtknode_dbg, {reply, Rep}} ->
	    ?LOG({reply,Rep}),loopDBGH();
	{cmd,quit} ->
	    gtknode_dbg ! quit;
	{cmd, Cmd} ->
	    gtknode_dbg ! {self(),Cmd},loopDBGH()
    end.

cmd(GUI,C,As) -> cmd(GUI,[{C,As}]).

cmd(GUI,CAs) ->
    GUI ! {self(),CAs},
    receive 
	{GUI,{reply,Reps}} -> Reps
    end.

%%%-------------------------------------------------------------------
%%% implements the gtkNode middleman process
%%% links to the gtkNode and to the signal handler
%%% the signal handler is the process from which the start function is called
%%%
%%% has a message API
%%% receives from the client;
%%%   {ClientPid, list({atom(Command),list(Args)})}
%%% receives from the port;
%%%   {port(Port),PortData}
%%% receives from the gtkNode;
%%%    {GtkPid, {atom(handshake|signal|reply|error),Data}
%%% from anywhere;
%%%    atom(quit) | EXIT signals
%%%-------------------------------------------------------------------
init(Client, Name) ->
    process_flag(trap_exit,true), 
    register(Name, self()),
    Client ! started,
    Port = start_gtknode(Name),
    waiting_handshake(#st{handler_pid=Client, name=Name, gtk_port=Port}).

start_gtknode(Name) ->
    open_port({spawn,make_cmd(Name)},[stderr_to_stdout,exit_status]).

make_cmd(Name) ->
    Path = join([code:priv_dir(?MODULE),bin]),
    Bin = "gtknode",
    case os:find_executable(Bin,Path) of
	false -> erlang:fault({executable_no_found,Bin});
	Exe -> 
	    [Node,Host] = string:tokens(atom_to_list(node()),"@"),
	    RegName = atom_to_list(Name),
	    Cookie = atom_to_list(erlang:get_cookie()),
	    NN = atom_to_list(?MODULE)++"_"++atom_to_list(Name),
	    EDV = integer_to_list(erl_dist_vsn()),
	    string_join([Exe,Node,Host,RegName,Cookie,NN,EDV]," ")
    end.

erl_dist_vsn() ->
    case string:tokens(erlang:system_info(version),".") of
	[[X]|_] when X < $5-> throw({ancient_erl_version,[X]});
	["5","0"|_] -> 7;
	["5","1"|_] -> 7;
	["5","2"|_] -> 8;
	["5","3"|_] -> 9;
	["5","4"|_] ->10;
	["5","5"|_] ->11;
	_ -> 12
    end.

string_join([Pref|Toks], Sep) ->
    lists:foldl(fun(Tok,O) -> O++Sep++Tok end, Pref, Toks).
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% the states; waiting_handshake, idle, waiting_reply
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
waiting_handshake(St = #st{gtk_port=Port}) ->
    receive
	{{GtkPid,handshake}, []} -> 
	    link(GtkPid),
	    idle(St#st{gtk_pid=GtkPid});
	{Port,PortData} ->			%from the port
	    waiting_handshake(handle_portdata(St, PortData));
	{'EXIT',Port,Reason} ->                 %port died, us too
	    die({port_died,Reason});
	quit -> 
	    die(quitting)
    after 
	?BORED -> waiting_handshake(bored(waiting_handshake,St))
    end.

idle(St = #st{gtk_pid=GtkPid, gtk_port=Port, handler_pid=HandPid}) ->
    receive
	{{GtkPid, signal}, Sig} ->
	    %%from gtknode
	    HandPid ! {St#st.name, {signal, Sig}},
	    idle(St);
	{Pid,CmdArgs} when pid(Pid) ->
	    %%from client
	    GtkPid ! CmdArgs,
	    waiting(St#st{client_pid = Pid},CmdArgs);
	{Port,PortData} ->
	    %%from the port
	    idle(handle_portdata(St, PortData));
	{'EXIT',HandPid,Reason} ->
	    %%handler died
	    die({handler_died,Reason});
	{'EXIT',Port,Reason} ->
	    %%port died, us too
	    die({port_died,Reason});
	quit -> 
	    die(quitting)
    end.

waiting(St = #st{gtk_pid=GtkPid, gtk_port=Port},CmdArgs) ->
    receive
	{{GtkPid,reply}, Ans}->			%from gtknode
	    St#st.client_pid ! {St#st.name, {reply,Ans}},
	    idle(St#st{client_pid = []});
	{Port,{data,PortData}} ->		%from the port
	    waiting(handle_portdata(St, PortData),CmdArgs);
	{'EXIT',Port,Reason} ->                 %port died, us too
	    die({port_died,{Reason,CmdArgs}});
	quit -> 
	    die(quitting)
    after 
	?BORED -> waiting(bored(waiting,St),CmdArgs)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
handle_portdata(St, PortData) ->
    case PortData of
	{data, Str} -> ?LOG({portdata, Str});
	_ -> ?LOG({portdata,PortData})
    end,
    St.

bored(State,St) ->
    ?LOG([{bored,State}, {state,St}, {msgs,process_info(self(),messages)}]),
    St.

die(Reason) ->
    process_flag(trap_exit,false),     
    exit({dying,Reason}).

log(ProcInfo,Term) when not is_list(Term) -> log(ProcInfo,[Term]);
log(ProcInfo,List) ->
    error_logger:info_report([{in,CF}||{current_function,CF}<-ProcInfo]++List).
