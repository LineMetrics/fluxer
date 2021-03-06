-module(fluxer).

-export([start_link/1]).
-export([pool_name/0]).
-export([create_database/1]).
-export([create_database/2]).
-export([show_databases/0]).
-export([write/3, write/4, write/5]).
-export([write_batch/2, write_batch/3]).
-export([select/2, select/3]).
-export([query/2, query_epoch_ms/2]).

-define(POOL_NAME, fluxer_pool).
-define(CT, {<<"Content-Type">>, <<"text/plain">>}).

%%====================================================================
%% API
%%====================================================================

start_link([Host, Port, IsSSL, Options]) ->
    fusco:start_link({Host, Port, IsSSL}, Options).

-spec pool_name() -> atom().
pool_name() ->
    ?POOL_NAME.

-spec create_database(string()) -> term().
create_database(Name) ->
    create_database(Name, false).

-spec create_database(string() | boolean() | atom(), boolean()) -> term().
create_database(Name, IfNotExists) when is_list(Name) ->
    create_database(to_binary(Name), IfNotExists);
create_database(Name, IfNotExists) when is_atom(Name) ->
    create_database(to_binary(Name), IfNotExists);
create_database(Name, IfNotExists) when is_binary(Name), is_boolean(IfNotExists) ->
    Query = case IfNotExists of
                true -> [<<"CREATE DATABASE IF NOT EXISTS ">>, Name];
                false -> [<<"CREATE DATABASE ">>, Name]
            end,
    case query(Query) of
        {ok, _Resp} -> ok;
        Error -> Error
    end.

-spec show_databases() -> term().
show_databases() ->
    query(<<"SHOW DATABASES">>).

select(DB, Measurement) ->
    Query = <<"SELECT * FROM ", (to_binary(Measurement))/binary>>,
    select_2(DB, Query).

select(DB, Measurement, Cols) ->
    ComposedCols = compose_cols(Cols, <<>>),
    Query = <<"SELECT ", ComposedCols/binary, " FROM ", (to_binary(Measurement))/binary>>,
    select_2(DB, Query).

write_batch(DB, Data) when is_list(Data) ->
    write_batch(DB, Data, undefined).
write_batch(DB, Data, Precision) when is_list(Data) ->
    Line = compose_batch_2(Data, <<>>),
    write_lines(DB, Line, Precision).

write(DB, Measurement, Value) ->
    write(DB, Measurement, [], Value).

write(DB, Measurement, [], Value) ->
    write_lines(DB, line(Measurement, Value));
write(DB, Measurement, Tags, Values) ->
    write_lines(DB, line(Measurement, Tags, Values)).

write(DB, Measurement, Tags, Values, TimeStamp) ->
    write_lines(DB, line(Measurement, Tags, Values, TimeStamp)).


-spec write_lines(binary()|list(), list()) -> ok | delivery_failed | any().
write_lines(DB, Data) when is_binary(Data) ->
    write_lines(DB, Data, undefined);
write_lines(DB, Data) when is_list(Data) ->
    write_lines(DB, list_to_binary(Data), undefined).

write_lines(DB, Data, Prec) when is_binary(Data) ->
    IO0 = case is_binary(Prec) of
              true -> [<<"&precision=", Prec/binary>>];
              false -> []
          end,
    Path = iolist_to_binary([[<<"/write?db=">>, to_binary(DB)] | IO0]),
    io:format("fluxer request: ~p",[Path]),
    Fun = fun(W) ->
        fusco:request(W, Path, <<"POST">>, maybe_add_auth([?CT]), Data, 5000)
          end,
    case poolboy:transaction(?POOL_NAME, Fun) of
        {ok, {{<<"204">>, _}, _Hdrs, _Resp, _, _}} ->               ok;
        Error -> Error
    end.

query(DB, Query) ->
    query_2(iolist_to_binary([<<"/query?db=">>, to_binary(DB), <<"&q=">>, to_binary(Query)])).

query_epoch_ms(DB, Query) ->
    query_2(iolist_to_binary([<<"/query?epoch=ms&db=">>, to_binary(DB), <<"&q=">>, to_binary(Query)])).

%%====================================================================
%% Internal functions
%%====================================================================

maybe_add_auth(Headers) ->
    case application:get_env(?MODULE, username) of
        {ok, Username} ->
            {ok, Password} = application:get_env(?MODULE, password),
            Base64 = base64:encode(<<(to_binary(Username))/binary, ":", (to_binary(Password))/binary>>),
            [{<<"Authorization">>, <<"Basic ", Base64/binary>>} | Headers];
        _Skip ->
            Headers
    end.

compose_batch_2([], Acc) ->
    Acc;
compose_batch_2([{Measurement, Tags, Values, TimeStamp}], Acc) ->
    <<Acc/binary, (line(Measurement, Tags, Values, TimeStamp))/binary>>;
compose_batch_2([{Measurement, Tags, Values, TimeStamp} | Rest], Acc) ->
    NewAcc = <<Acc/binary, (line(Measurement, Tags, Values, TimeStamp))/binary, "\n">>,
    compose_batch_2(Rest, NewAcc).

line(Measurement, Value) ->
    iolist_to_binary([to_binary(Measurement), <<" value=">>, maybe_integer(Value)]).

line(Measurement, Tags, Values) ->
    iolist_to_binary([to_binary(Measurement), <<",">>, compose_tags(Tags),
        <<" ">>, compose_values(Values)]).

line(Measurement, Tags, Values, TimeStamp) ->
    BinLine = line(Measurement, Tags, Values),
    TimeBin = to_binary(TimeStamp),
    <<BinLine/binary, " ", TimeBin/binary>>.

-spec select_2(string() | binary() | atom(), string() | binary()) -> term().
select_2(DB, Query) ->
    query(to_binary(DB), to_binary(Query)).

-spec query(iodata() | binary()) -> term().
query(Query) when is_list(Query) ->
    query(iolist_to_binary(Query));
query(Query) when is_binary(Query) ->
    query_2(iolist_to_binary([<<"/query?q=">>, Query])).

query_2(Query) when is_binary(Query) ->
    Query2 = binary:replace(Query, <<" ">>, <<"%20">>, [global]),
    Fun = fun(W) ->
        fusco:request(W, Query2, <<"GET">>, maybe_add_auth([]), [], 5000)
          end,
    case poolboy:transaction(?POOL_NAME, Fun) of
        {ok, {{<<"200">>, _}, _Hdrs, Resp, _, _}} ->
            {ok, jsx:decode(Resp)};
        Error ->
            Error
    end.

compose_tags(Tags) ->
    compose_tags(Tags, <<>>).

compose_tags([], Acc) ->
    Acc;
compose_tags([{Key, Value} | Rest], <<>>) ->
    NewAcc = <<(to_binary(Key))/binary, "=", (to_binary(Value))/binary>>,
    compose_tags(Rest, NewAcc);
compose_tags([{Key, Value} | Rest], Acc) ->
    NewAcc = <<(to_binary(Key))/binary, "=", (to_binary(Value))/binary, ",", Acc/binary>>,
    compose_tags(Rest, NewAcc).

compose_values(Values) ->
    compose_values(Values, <<>>).

compose_values([], Acc) ->
    Acc;
compose_values([{Key, Value} | Rest], <<>>) ->
    NewAcc = <<(to_binary(Key))/binary, "=", (to_number_binary(Value))/binary>>,
    compose_values(Rest, NewAcc);
compose_values([{Key, Value} | Rest], Acc) ->
    NewAcc = <<(to_binary(Key))/binary, "=", (to_number_binary(Value))/binary, ",", Acc/binary>>,
    compose_values(Rest, NewAcc).

compose_cols([], Acc) ->
    Acc;
compose_cols([Col | Cols], <<>>) ->
    compose_cols(Cols, <<(to_binary(Col))/binary>>);
compose_cols([Col | Cols], Acc) ->
    compose_cols(Cols, <<(to_binary(Col))/binary, ",", Acc/binary>>).

maybe_integer(Value) when is_integer(Value) ->
    <<(to_binary(Value))/binary, "i">>;
maybe_integer(Value) ->
    to_binary(Value).

to_number_binary(Value) when is_binary(Value) ->
    to_binary(binary_to_number(Value));
to_number_binary(Value) ->
    to_binary(Value).

binary_to_number(Bin) ->
    list_to_number(binary_to_list(Bin)).

list_to_number(List) ->
    try list_to_float(List)
    catch
        error:badarg ->
            list_to_integer(List)
    end.

to_binary(Value) when is_integer(Value) ->
    integer_to_binary(Value);
to_binary(Value) when is_list(Value) ->
    list_to_binary(Value);
to_binary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
to_binary(Value) when is_float(Value) ->
    list_to_binary(float_to_list(Value));
to_binary(Value) when is_binary(Value) ->
    Value.
