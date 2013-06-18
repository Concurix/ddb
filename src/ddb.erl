%%% Copyright (C) 2012 Issuu ApS. All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions
%%% are met:
%%% 1. Redistributions of source code must retain the above copyright
%%%    notice, this list of conditions and the following disclaimer.
%%% 2. Redistributions in binary form must reproduce the above copyright
%%%    notice, this list of conditions and the following disclaimer in the
%%%    documentation and/or other materials provided with the distribution.
%%%
%%% THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
%%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%%% ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
%%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%%% SUCH DAMAGE.

-module(ddb).

-export([credentials/3, credentials/4, tables/0,
         key_type/2, key_type/4,
         key_value/2, key_value/4,
         create_table/4, describe_table/1, remove_table/1,
         get/2, get/3, put/2, update/3, update/4,
         delete/2, delete/3,
         cond_put/3,
         cond_update/4, cond_update/5,
         cond_delete/3, cond_delete/4,
         now/0, find/3, find/4,
         q/3, q/4,
         scan/2, scan/3,
         range_key_condition/1]).

-define(DDB_DOMAIN, "dynamodb.us-east-1.amazonaws.com").
-define(DDB_ENDPOINT, "https://" ++ get_ddb_domain() ++ "/").
-define(DDB_AMZ_PREFIX, "x-amz-").

-define(SIGNATURE_METHOD, "HmacSHA1").
-define(MAX_RETRIES, 4).

%%% Request headers

-define(HOST_HEADER, "Host").
-define(DATE_HEADER, "X-Amz-Date").
-define(AUTHORIZATION_HEADER, "X-Amzn-Authorization").
-define(TOKEN_HEADER, "x-amz-security-token").
-define(TARGET_HEADER, "X-Amz-Target").
-define(CONTENT_TYPE_HEADER, "Content-Type").

-define(CONTENT_TYPE, "application/x-amz-json-1.0").

%%% Endpoint targets

-define(TG_VERSION, "DynamoDB_20111205.").
-define(TG_CREATE_TABLE, ?TG_VERSION ++ "CreateTable").
-define(TG_LIST_TABLES, ?TG_VERSION ++ "ListTables").
-define(TG_DESCRIBE_TABLE, ?TG_VERSION ++ "DescribeTable").
-define(TG_DELETE_TABLE, ?TG_VERSION ++ "DeleteTable").
-define(TG_PUT_ITEM, ?TG_VERSION ++ "PutItem").
-define(TG_GET_ITEM, ?TG_VERSION ++ "GetItem").
-define(TG_UPDATE_ITEM, ?TG_VERSION ++ "UpdateItem").
-define(TG_DELETE_ITEM, ?TG_VERSION ++ "DeleteItem").
-define(TG_QUERY, ?TG_VERSION ++ "Query").
-define(TG_SCAN, ?TG_VERSION ++ "Scan").

-define(HTTP_OPTIONS, []).

-type tablename() :: binary().
-type type() :: 'number' | 'string' | ['number'] | ['string'].
-type condition() :: 'between' | 'equal'. % TBD implement others
-type key_value() :: {binary(), type()}.
-type find_cond() :: {condition(), type(), [_]}.
-type json() :: [_].
-type key_json() :: json().
-type json_reply() :: {'ok', json()} | {'error', json()}.
-type put_attr() :: {binary(), binary(), type()}.
-type update_action() :: 'put' | 'add' | 'delete'.
-type update_attr() :: {binary(), binary(), type(), 'put' | 'add'} | {binary(), 'delete'}.
-type returns() :: 'none' | 'all_old' | 'updated_old' | 'all_new' | 'updated_new'.
-type update_cond() :: {'does_not_exist', binary()} | {'exists', binary(), binary(), type()}.
-type json_parameter() :: {binary(), term()}.
-type json_parameters() :: [json_parameter()].

%%% Set temporary credentials, use ddb_iam:token/1 to fetch from AWS.

-spec credentials(string(), string(), string()) -> 'ok'.

credentials(AccessKeyId, SecretAccessKey, SessionToken) ->
    'ok' = application:set_env('ddb', 'accesskeyid', AccessKeyId),
    'ok' = application:set_env('ddb', 'secretaccesskey', SecretAccessKey),
    'ok' = application:set_env('ddb', 'sessiontoken', SessionToken).

-spec credentials(string(), string(), string(), string()) -> 'ok'.

credentials(AccessKeyId, SecretAccessKey, SessionToken, DDBDomain) ->
    'ok' = application:set_env('ddb', 'ddb_domain', DDBDomain),
    credentials(AccessKeyId, SecretAccessKey, SessionToken).

%%% Retrieve stored credentials.

-spec credentials() -> {'ok', string(), string(), string()}.

credentials() ->
    {'ok', AccessKeyId} = application:get_env('ddb', 'accesskeyid'),
    {'ok', SecretAccessKey} = application:get_env('ddb', 'secretaccesskey'),
    {'ok', SessionToken} = application:get_env('ddb', 'sessiontoken'),
    {'ok', AccessKeyId, SecretAccessKey, SessionToken}.

%%% Create a key type, either hash or hash and range.

-spec key_type(binary(), type()) -> json().

key_type(HashKey, HashKeyType)
  when is_binary(HashKey),
       is_atom(HashKeyType) ->
    [{<<"HashKeyElement">>,
      [{<<"AttributeName">>, HashKey},
       {<<"AttributeType">>, type(HashKeyType)}]}].

-spec key_type(binary(), type(), binary(), type()) -> json().

key_type(HashKey, HashKeyType, RangeKey, RangeKeyType)
  when is_binary(HashKey),
       is_atom(HashKeyType),
       is_binary(RangeKey),
       is_atom(RangeKeyType) ->
    [{<<"HashKeyElement">>,
      [{<<"AttributeName">>, HashKey},
       {<<"AttributeType">>, type(HashKeyType)}]},
     {<<"RangeKeyElement">>,
      [{<<"AttributeName">>, RangeKey},
       {<<"AttributeType">>, type(RangeKeyType)}]}].

%%% Create table. Use key_type/2 or key_type/4 as key.

-spec create_table(tablename(), key_json(), pos_integer(), pos_integer()) -> json_reply().

create_table(Name, Keys, ReadsPerSec, WritesPerSec)
  when is_binary(Name),
       is_list(Keys),
       is_integer(ReadsPerSec),
       is_integer(WritesPerSec) ->
    JSON = [{<<"TableName">>, Name},
            {<<"KeySchema">>, Keys},
            {<<"ProvisionedThroughput">>, [{<<"ReadCapacityUnits">>, ReadsPerSec},
                                           {<<"WriteCapacityUnits">>, WritesPerSec}]}],
    request(?TG_CREATE_TABLE, JSON).

%%% Fetch list of created tabled.

-spec tables() -> {'ok', [tablename()]}.

tables() ->
    {'ok', JSON} = request(?TG_LIST_TABLES, [{}]),
    [{<<"TableNames">>, Tables}] = JSON,
    {'ok', Tables}.

%%% Describe table.

-spec describe_table(tablename()) -> json_reply().

describe_table(Name)
  when is_binary(Name) ->
    JSON = [{<<"TableName">>, Name}],
    request(?TG_DESCRIBE_TABLE, JSON).

%%% Delete table.

-spec remove_table(tablename()) -> json_reply().

remove_table(Name)
  when is_binary(Name) ->
    JSON = [{<<"TableName">>, Name}],
    request(?TG_DELETE_TABLE, JSON).

%%% Put item attributes into table.

-spec put(tablename(), [put_attr()]) -> json_reply().

put(Name, Attributes)
  when is_binary(Name) ->
    JSON = [{<<"TableName">>, Name},
            {<<"Item">>, format_put_attrs(Attributes)}],
    request(?TG_PUT_ITEM, JSON).

%%% Conditionally put item attributes into table

-spec cond_put(tablename(), [put_attr()], update_cond()) -> json_reply().

cond_put(Name, Attributes, Condition)
  when is_binary(Name),
       is_list(Attributes) ->
    JSON = [{<<"TableName">>, Name},
            {<<"Item">>, format_put_attrs(Attributes)}]
        ++ format_update_cond(Condition),
    request(?TG_PUT_ITEM, JSON).

%%% Create a key value, either hash or hash and range.

-spec key_value(binary(), type()) -> json().

key_value(HashKeyValue, HashKeyType)
  when is_binary(HashKeyValue),
       is_atom(HashKeyType) ->
    [{<<"Key">>, [{<<"HashKeyElement">>,
                   [{type(HashKeyType), HashKeyValue}]}]}].

-spec key_value(binary(), type(), binary(), type()) -> json().

key_value(HashKeyValue, HashKeyType, RangeKeyValue, RangeKeyType)
  when is_binary(HashKeyValue),
       is_atom(HashKeyType),
       is_binary(RangeKeyValue),
       is_atom(RangeKeyType) ->
    [{<<"Key">>, [{<<"HashKeyElement">>,
                   [{type(HashKeyType), HashKeyValue}]},
                  {<<"RangeKeyElement">>,
                   [{type(RangeKeyType), RangeKeyValue}]}]}].

%%% Update attributes of an existing item.

-spec update(tablename(), key_json(), [update_attr()]) -> json_reply().

update(Name, Keys, Attributes) ->
    update(Name, Keys, Attributes, 'none').

-spec update(tablename(), key_json(), [update_attr()], returns()) -> json_reply().

update(Name, Keys, Attributes, Returns)
  when is_binary(Name),
       is_list(Keys),
       is_list(Attributes),
       is_atom(Returns) ->
    JSON = [{<<"TableName">>, Name},
            {<<"ReturnValues">>, returns(Returns)}]
        ++ Keys
        ++ [{<<"AttributeUpdates">>, format_update_attrs(Attributes)}],
    request(?TG_UPDATE_ITEM, JSON).

%%% Conditionally update attributes of an existing item.

-spec cond_update(tablename(), key_json(), [update_attr()], update_cond()) -> json_reply().

cond_update(Name, Keys, Attributes, Condition) ->
    cond_update(Name, Keys, Attributes, Condition, 'none').

-spec cond_update(tablename(), key_json(), [update_attr()], update_cond(), returns()) -> json_reply().

cond_update(Name, Keys, Attributes, Condition, Returns)
  when is_binary(Name),
       is_list(Keys),
       is_list(Attributes),
       is_atom(Returns) ->
    JSON = [{<<"TableName">>, Name},
            {<<"ReturnValues">>, returns(Returns)}]
        ++ Keys
        ++ [{<<"AttributeUpdates">>, format_update_attrs(Attributes)}]
        ++ format_update_cond(Condition),
    request(?TG_UPDATE_ITEM, JSON).

%%% Delete existing item.

-spec delete(tablename(), key_json()) -> json_reply().

delete(Name, Keys) ->
    delete(Name, Keys, 'none').

-spec delete(tablename(), key_json(), returns()) -> json_reply().

delete(Name, Keys, Returns)
  when is_binary(Name),
       is_list(Keys),
       is_atom(Returns) ->
    JSON = [{<<"TableName">>, Name},
            {<<"ReturnValues">>, returns(Returns)}]
        ++ Keys,
    request(?TG_DELETE_ITEM, JSON).

%%% Conditionally delete existing item.

-spec cond_delete(tablename(), key_json(), update_cond()) -> json_reply().

cond_delete(Name, Keys, Condition) ->
    cond_delete(Name, Keys, Condition, 'none').

-spec cond_delete(tablename(), key_json(), update_cond(), returns()) -> json_reply().

cond_delete(Name, Keys, Condition, Returns)
  when is_binary(Name),
       is_list(Keys),
       is_atom(Returns) ->
    JSON = [{<<"TableName">>, Name},
            {<<"ReturnValues">>, returns(Returns)}]
        ++ Keys
        ++ format_update_cond(Condition),
    request(?TG_DELETE_ITEM, JSON).

%%% Fetch all item attributes from table.

-spec get(tablename(), key_json()) -> json_reply().

get(Name, Keys)
  when is_binary(Name),
       is_list(Keys) ->
    JSON = [{<<"TableName">>, Name}] ++ Keys,
    request(?TG_GET_ITEM, JSON).

%%% get with additional parameters

-spec get(tablename(), key_json(), json_parameters()) -> json_reply().

get(Name, Keys, Parameters)
  when is_binary(Name),
       is_list(Keys) ->
    JSON = [{<<"TableName">>, Name}]
        ++ Keys
        ++ Parameters,
    request(?TG_GET_ITEM, JSON).

%%% Fetch all item attributes from table using a condition.

-spec find(tablename(), key_value(), find_cond()) -> json_reply().

find(Name, HashKey, RangeKeyCond) ->
    find(Name, HashKey, RangeKeyCond, 'none').

%%% Fetch all item attributes from table using a condition, with pagination.

-spec find(tablename(), key_value(), find_cond(), json() | 'none') -> json_reply().

find(Name, {HashKeyValue, HashKeyType}, RangeKeyCond, StartKey)
  when is_binary(Name),
       is_binary(HashKeyValue),
       is_atom(HashKeyType) ->
    JSON = [{<<"TableName">>, Name},
            {<<"HashKeyValue">>,
             [{type(HashKeyType), HashKeyValue}]},
            range_key_condition(RangeKeyCond)]
        ++ start_key(StartKey),

    request(?TG_QUERY, JSON).

%%% Create a range key condition parameter

-spec range_key_condition(find_cond()) -> json_parameter().
range_key_condition({Condition, RangeKeyType, RangeKeyValues})
  when is_atom(Condition),
       is_atom(RangeKeyType),
       is_list(RangeKeyValues) ->
    {Op, Values} = case Condition of
                       'between' ->
                           [A, B] = RangeKeyValues,
                           {<<"BETWEEN">>, [[{type(RangeKeyType), A}],
                                            [{type(RangeKeyType), B}]]};
                       'equal' ->
                           {<<"EQ">>, [[{type(RangeKeyType), hd(RangeKeyValues)}]]}
                   end,
    {<<"RangeKeyCondition">>, [{<<"AttributeValueList">>, Values},
                               {<<"ComparisonOperator">>, Op}]}.

%%% Query a table

-spec q(tablename(), key_value(), json_parameters()) -> json_reply().

q(Name, HashKey, Parameters) ->
    q(Name, HashKey, Parameters, 'none').

%% Query a table with pagination

-spec q(tablename(), key_value(), json_parameters(), json() | 'none') -> json_reply().

q(Name, {HashKeyValue, HashKeyType}, Parameters, StartKey)
  when is_binary(Name),
       is_binary(HashKeyValue),
       is_atom(HashKeyType),
       is_list(Parameters) ->
    JSON = [{<<"TableName">>, Name},
            {<<"HashKeyValue">>, [{type(HashKeyType), HashKeyValue}]}]
        ++ Parameters
        ++ start_key(StartKey),
    request(?TG_QUERY, JSON).

%%% Scan a table

-spec scan(tablename(), json_parameters()) -> json_reply().

scan(Name, Parameters) ->
    scan(Name, Parameters, 'none').

%% Scan a table with pagination

-spec scan(tablename(), json_parameters(), json() | 'none') -> json_reply().

scan(Name, Parameters, StartKey)
  when is_binary(Name),
       is_list(Parameters) ->
    JSON = [{<<"TableName">>, Name}]
        ++ Parameters
        ++ start_key(StartKey),
    request(?TG_SCAN, JSON).

%%%
%%% Helper functions
%%%

-spec get_ddb_domain() -> string().

get_ddb_domain() ->
    case application:get_env('ddb', 'ddb_domain') of
        {'ok', DDBDomain} ->
            DDBDomain;
        _ ->
            ?DDB_DOMAIN
    end.

-spec start_key(json() | 'none') -> json_parameters().
start_key('none') ->
    [];
start_key(StartKey) ->
    [{<<"ExclusiveStartKey">>, StartKey}].

-spec format_put_attrs([put_attr()]) -> json().

format_put_attrs(Attributes) ->
    lists:map(fun({Name, Value, Type}) ->
                      {Name, [{type(Type), Value}]}
              end, Attributes).

-spec format_update_attrs([update_attr()]) -> json().

format_update_attrs(Attributes) ->
    lists:map(fun({Name, Value, Type, Action}) ->
                      {Name, [{<<"Value">>, [{type(Type), Value}]},
                              {<<"Action">>, update_action(Action)}]};
                 ({Name, 'delete'}) ->
                      {Name, [{<<"Action">>, update_action('delete')}]}
              end, Attributes).

-spec format_update_cond(update_cond()) -> json().

format_update_cond({'does_not_exist', Name}) ->
    [{<<"Expected">>, [{Name, [{<<"Exists">>, <<"false">>}]}]}];

format_update_cond({'exists', Name, Value, Type}) ->
    [{<<"Expected">>, [{Name, [{<<"Value">>, [{type(Type), Value}]}]}]}].

-spec type(type()) -> binary().

type('string') -> <<"S">>;
type('number') -> <<"N">>;
type(['string']) -> <<"SS">>;
type(['number']) -> <<"NN">>.

-spec returns(returns()) -> binary().

returns('none') -> <<"NONE">>;
returns('all_old') -> <<"ALL_OLD">>;
returns('updated_old') -> <<"UPDATED_OLD">>;
returns('all_new') -> <<"ALL_NEW">>;
returns('updated_new') -> <<"UPDATED_NEW">>.

-spec update_action(update_action()) -> binary().

update_action('put') -> <<"PUT">>;
update_action('add') -> <<"ADD">>;
update_action('delete') -> <<"DELETE">>.

-spec request(string(), json()) -> json_reply().

request(Target, JSON) ->
    Body = jsx:term_to_json(JSON),
    %%ok = lager:debug("REQUEST BODY ~n~p", [Body]),
    Headers = headers(Target, Body),
    Opts = [{'response_format', 'binary'}],
    F = fun() -> ibrowse:send_req(?DDB_ENDPOINT, [{'Content-type', ?CONTENT_TYPE} | Headers], 'post', Body, Opts) end,
    case ddb_aws:retry(F, ?MAX_RETRIES, fun jsx:json_to_term/1) of
        {'error', 'expired_token'} ->
            {ok, Key, Secret, Token} = ddb_iam:token(129600),
            ddb:credentials(Key, Secret, Token),
            request(Target, JSON);
        Else ->
            Else
    end.

-spec headers(string(), binary()) -> proplists:proplist().

headers(Target, Body) ->
    {'ok', AccessKeyId, SecretAccessKey, SessionToken} = credentials(),
    Date = ddb_util:rfc1123_date(),
    Headers = [{?DATE_HEADER, Date},
               {?TARGET_HEADER, Target},
               {?TOKEN_HEADER, SessionToken},
               {?CONTENT_TYPE_HEADER, ?CONTENT_TYPE}],
    Authorization = authorization(AccessKeyId, SecretAccessKey, Headers, Body),
    [{?AUTHORIZATION_HEADER, Authorization}|Headers].

-spec authorization(string(), string(), proplists:proplist(), binary()) -> string().

authorization(AccessKeyId, SecretAccessKey, Headers, Body) ->
    Signature = signature(SecretAccessKey, Headers, Body),
    lists:flatten(io_lib:format("AWS3 AWSAccessKeyId=~s,Algorithm=~s,Signature=~s",
                                [AccessKeyId, ?SIGNATURE_METHOD, Signature])).

-spec signature(string(), proplists:proplist(), binary()) -> string().

signature(SecretAccessKey, Headers, Body) ->
    StringToSign = lists:flatten(["POST", $\n, "/", $\n, $\n, canonical(Headers), $\n, Body]),
    BytesToSign = crypto:sha(StringToSign),
    base64:encode_to_string(binary_to_list(crypto:sha_mac(SecretAccessKey, BytesToSign))).

-spec canonical(proplists:proplist()) -> [_].

canonical(Headers) ->
    Headers1 = lists:map(fun({K, V}) -> {ddb_util:to_lower(K), V} end, Headers),
    Amz = lists:filter(fun({K, _V}) -> lists:prefix(?DDB_AMZ_PREFIX, K) end, Headers1),
    Headers2 = [{ddb_util:to_lower(?HOST_HEADER), get_ddb_domain()}|lists:sort(Amz)],
    lists:map(fun({K, V}) -> [K, ":", V, "\n"] end, Headers2).

-spec now() -> pos_integer().

now() ->
    Time = calendar:local_time(),
    Seconds = calendar:datetime_to_gregorian_seconds(Time),
    Seconds - 62167219200. % Unix time
