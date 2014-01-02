open Core.Std
open Async.Std
module Co = Cohttp
module B64 = Co.Base64

let keyc =
  object
    method encode = Fn.compose (Uri.pct_encode ~component:`Query_key) B64.encode
    method decode = Fn.compose B64.decode Uri.pct_decode
  end

(* work around since cohttp doesn't support = in values *)
let valc = keyc

module Env = struct
  type cookie = (string * string) list
  let key : cookie Univ_map.Key.t =
    Univ_map.Key.create "cookie" sexp_of_opaque
end

let current_cookies req =
  Option.value ~default:[] (Univ_map.find (Rock.Request.env req) Env.key)

let cookies_raw req = req
                      |> Rock.Request.request
                      |> Co.Request.headers
                      |> Co.Cookie.Cookie_hdr.extract

let cookies req = req
                  |> cookies_raw
                  |> List.filter_map ~f:(fun (k,v) ->
                    (* ignore bad cookies *)
                    Option.try_with @@ fun () -> (keyc#decode k, valc#decode v))

let get req ~key =
  let cookies = cookies_raw req in
  let encoded_key = encode key in
  cookies |> List.find_map ~f:(fun (k,v) ->
    let encoded_key = keyc#encode key in
           if k = encoded_key then Some (valc#decode v) else None)

let set_cookies req cookies =
  let env = Rock.Request.env req in
  let current_cookies = current_cookies req in
  let all_cookies = current_cookies @ cookies in (* TODO: wrong *)
  Rock.Request.set_env req (Univ_map.set env Env.key all_cookies)

let set req ~key ~data = set_cookies req [(key, data)]

let m handler req =             (* TODO: "optimize" *)
  Rock.Handler.call handler req >>| fun response ->
  let cookie_headers =
    let module Cookie = Co.Cookie.Set_cookie_hdr in
    let f (k,v) =
      (keyc#encode k, valc#encode v) |> Cookie.make ~path:"/" |> Cookie.serialize
    in current_cookies req |> List.map ~f in
  let old_headers = Rock.Response.headers response in
  { response with Rock.Response.headers=(
     List.fold_left cookie_headers ~init:old_headers
       ~f:(fun headers (k,v) -> Co.Header.add headers k v))
  }

