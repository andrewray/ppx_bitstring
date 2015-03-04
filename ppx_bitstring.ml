open Ast_helper
open Ast_lifter
open Ast_mapper
open Asttypes
open Core.Std
open Lexing
open Longident
open Parsetree
open Printf

(* Type definition *)

module Type = struct
  type t =
    | Int
    | String
    | Bitstring
end

module Sign = struct
  type t =
    | Signed
    | Unsigned
end

module Endian = struct
  type t =
    | Little
    | Big
    | Native
    | Referred of Parsetree.expression
end

type t = {
  value_type    : Type.t option;
  sign          : Sign.t option;
  endian        : Endian.t option;
  check         : Parsetree.expression option;
  bind          : Parsetree.expression option;
  set_offset_at : Parsetree.expression option;
}

let empty = {
  value_type    = None;
  sign          = None;
  endian        = None;
  check         = None;
  bind          = None;
  set_offset_at = None;
}

let default = {
  value_type    = Some Type.Int;
  sign          = Some Sign.Unsigned;
  endian        = Some Endian.Big;
  check         = None;
  bind          = None;
  set_offset_at = None;
}

(* Helper functions *)

let mksym =
  let i = ref 1000 in
  fun name ->
    incr i; let i = !i in
    sprintf "__ppxbitstring_%s_%d" name i

let mkpatvar name =
  Parse.pattern (Lexing.from_string name)

let mkident name =
  Parse.expression (Lexing.from_string name)

(* Processing qualifiers *)

let process_qual state q =
  match q with
  | [%expr int] ->
      begin match state.value_type with
      | Some v -> failwith "Value type can only be defined once"
      | None -> { state with value_type = Some Type.Int }
      end
  | [%expr string] ->
      begin match state.value_type with
      | Some v -> failwith "Value type can only be defined once"
      | None -> { state with value_type = Some Type.String }
      end
  | [%expr bitstring] ->
      begin match state.value_type with
      | Some v -> failwith "Value type can only be defined once"
      | None -> { state with value_type = Some Type.Bitstring }
      end
  | [%expr signed] ->
      begin match state.sign with
      | Some v -> failwith "Signedness can only be defined once"
      | None -> { state with sign = Some Sign.Signed }
      end
  | [%expr unsigned] ->
      begin match state.sign with
      | Some v -> failwith "Signedness can only be defined once"
      | None -> { state with sign = Some Sign.Unsigned }
      end
  | [%expr littleendian] ->
      begin match state.endian with
      | Some v -> failwith "Endianness can only be defined once"
      | None -> { state with endian = Some Endian.Little }
      end
  | [%expr bigendian] ->
      begin match state.endian with
      | Some v -> failwith "Endianness can only be defined once"
      | None -> { state with endian = Some Endian.Big }
      end
  | [%expr nativeendian] ->
      begin match state.endian with
      | Some v -> failwith "Endianness can only be defined once"
      | None -> { state with endian = Some Endian.Native }
      end
  | [%expr endian [%e? sub]] ->
      begin match state.endian with
      | Some v -> failwith "Endianness can only be defined once"
      | None -> { state with endian = Some (Endian.Referred sub) }
      end
  | [%expr bind [%e? sub]] ->
      begin match state.check with
      | Some v -> failwith "Check expression can only be defined once"
      | None -> { state with check = Some sub }
      end
  | [%expr check [%e? sub]] ->
      begin match state.bind with
      | Some v -> failwith "Bind expression can only be defined once"
      | None -> { state with bind = Some sub }
      end
  | [%expr set_offset_at [%e? sub]] ->
      begin match state.set_offset_at with
      | Some v -> failwith "Offset expression can only be defined once"
      | None -> { state with set_offset_at = Some sub }
      end
  | _ -> failwith ("Invalid qualifier: " ^ (Pprintast.string_of_expression q))

let parse_quals str =
  let expr = Parse.expression (Lexing.from_string str) in
  let rec process_quals state = function
    | [] -> state
    | hd :: tl -> process_quals (process_qual state hd) tl
  in match expr with
  (* single named qualifiers *)
  | { pexp_desc = Pexp_ident (_) } -> process_qual empty expr
  (* single functional qualifiers *)
  | { pexp_desc = Pexp_apply (_, _) } -> process_qual empty expr
  (* multiple qualifiers *)
  | { pexp_desc = Pexp_tuple (elements) } -> process_quals empty elements
  | _ -> failwith ("Format error: " ^ str)

(* Processing expression *)

let rec evaluate_expr = function
  | { pexp_desc =
      Pexp_apply ({ pexp_desc = Pexp_ident ({ txt; _ }); _ }, [ (_, lhs); (_, rhs) ] ) } ->
      let elhs = evaluate_expr lhs and erhs = evaluate_expr rhs in
      begin match txt with
      | Lident ("+") ->
          begin match elhs, erhs with
          | Some l, Some r -> Some (l + r)
          | _ -> None
          end
      | Lident ("-") ->
          begin match elhs, erhs with
          | Some l, Some r -> Some (l - r)
          | _ -> None
          end
      | Lident ("*") ->
          begin match elhs, erhs with
          | Some l, Some r -> Some (l * r)
          | _ -> None
          end
      | Lident ("/") ->
          begin match elhs, erhs with
          | Some l, Some r -> Some (l / r)
          | _ -> None
          end
      | Lident ("land") ->
          begin match elhs, erhs with
          | Some l, Some r -> Some (l land r)
          | _ -> None
          end
      | Lident ("lor") ->
          begin match elhs, erhs with
          | Some l, Some r -> Some (l lor r)
          | _ -> None
          end
      | Lident ("lxor") ->
          begin match elhs, erhs with
          | Some l, Some r -> Some (l lxor r)
          | _ -> None
          end
      | Lident ("lsr") ->
          begin match elhs, erhs with
          | Some l, Some r -> Some (l lsr r)
          | _ -> None
          end
      | Lident ("asr") ->
          begin match elhs, erhs with
          | Some l, Some r -> Some (l asr r)
          | _ -> None
          end
      | Lident ("mod") ->
          begin match elhs, erhs with
          | Some l, Some r -> Some (l mod r)
          | _ -> None
          end
      | _ -> None
      end
  | { pexp_desc = Pexp_constant (const) } ->
      begin match const with
      | Const_int i -> Some i
      | _ -> None
      end
  | _ ->
      None

let parse_expr str =
  Parse.expression (Lexing.from_string str)

(* Processing pattern *)

let pattern_lifter =
  object
    inherit [bool] Ast_lifter.lifter as super
    method record (_ : string) x =
      let rec scan_result v = function
        | [] -> v
        | (n, s) :: tl ->
            begin match n with
            | "ppat_attributes" | "ppat_loc" | "txt" | "loc" -> scan_result v tl
            | _ -> scan_result (s && v) tl
            end
     in
      scan_result true x
    method constr (_ : string) (c, args) =
      let rec scan_args v = function
        | [] -> v
        | hd :: tl -> scan_args (v && hd) tl
      in
      match c with
      | "Ppat_extension"  | "Ppat_exception"  | "Ppat_unpack"   | "Ppat_lazy"
      | "Ppat_type"       | "Ppat_constraint" | "Ppat_interval" | "Ppat_tuple" -> false
      | _ -> scan_args true args
    method list x = false
    method tuple x = false
    method string x = true
    method nativeint x = true
    method int x = true
    method int32 x = true
    method int64 x = true
    method char x = false
    method! lift_Location_t l = false
    method! lift_Parsetree_attributes l = false
  end

let parse_pattern str =
    let pat = Parse.pattern (Lexing.from_string str) in
    if pattern_lifter#lift_Parsetree_pattern (pat) then pat
    else failwith ("Format error: " ^ str)

(* Parsing fields *)

let parse_fields str =
  let e = List.fold_right ~init:[] ~f:(fun e acc -> [Bytes.trim e] @ acc) (String.split ~on:':' str) in
  match e with
  | [ "_" as pat ] ->
      (parse_pattern pat, None, None)
  | [ pat; len ] ->
      (parse_pattern pat, Some (parse_expr len), Some default)
  | [ pat; len; quals ] ->
      (parse_pattern pat, Some (parse_expr len), Some (parse_quals quals))
  | _ -> failwith ("Format error: " ^ str)

(* Generators *)

let check_field_len (l, q) =
  let open Option.Monad_infix in
  match q.value_type with
  | Some (Type.String) ->
      evaluate_expr l >>= fun v ->
        if v < -1 || (v > 0 && (v mod 8) <> 0) then
          failwith "length of string must be > 0 and multiple of 8, or the special value -1"
        else Some v
  | Some (Type.Bitstring) ->
      evaluate_expr l >>= fun v ->
        if v < -1 then failwith "length of bitstring must be >= 0 or the special value -1"
        else Some v
  | Some (Type.Int) ->
      evaluate_expr l >>= fun v ->
        if v < 1 || v > 64 then failwith "length of int field must be [1..64]"
        else Some v
  | None -> failwith "No type to check"

let generate_field (dat, res, off, len) (p, l, q) next =
  match check_field_len (l, q), q.value_type with
  | Some (-1), Some (Type.Bitstring) ->
      begin match p with
      | { ppat_desc = Ppat_var(_) } ->
          [%expr
          let [%p p] = ([%e (mkident dat)], [%e (mkident off)], [%e (mkident len)]) in
          [%e next]]
      | { ppat_desc = Ppat_any } -> next
      | _ -> failwith "Bistring can only be assigned to variables or skipped"
      end
  | Some (_), Some (Type.Bitstring) ->
      let offN = mksym "off" and lenN = mksym "len" in
      let body = [%expr
        let [%p (mkpatvar offN)] = [%e (mkident off)] + [%e l]
        and [%p (mkpatvar lenN)] = [%e (mkident len)] - [%e l]
        in [%e next]]
      in
      begin match p with
      | { ppat_desc = Ppat_var(_) } ->
          [%expr
          let [%p p] = ([%e (mkident dat)], [%e (mkident off)], [%e (mkident len)]) in
          [%e body]]
      | { ppat_desc = Ppat_any } -> body
      | _ -> failwith "Bistring can only be assigned to variables or skipped"
      end
  | Some (-1), Some (Type.String) ->
      begin match p with
      | { ppat_desc = Ppat_var(_) } ->
          [%expr
          let [%p p] = ([%e (mkident dat)], [%e (mkident off)], [%e (mkident len)]) in
          [%e next]]
      | { ppat_desc = Ppat_any } -> next
      | _ -> failwith "Bistring can only be assigned to variables or skipped"
      end
  | Some (_), Some (Type.String) ->
      let valN = mksym "value" and offN = mksym "off" and lenN = mksym "len" in
      [%expr
      let [%p (mkpatvar valN)] = 0 in
      let [%p (mkpatvar offN)] = [%e (mkident off)] + [%e l]
      and [%p (mkpatvar lenN)] = [%e (mkident len)] - [%e l]
      in match [%e (mkident valN)] with
      | [%p p] when true -> [%e next]
      | _ -> ()]
  | field_len, Some (_) ->
      let valN = mksym "value" and offN = mksym "off" and lenN = mksym "len" in
      [%expr
      if [%e (mkident len)] >= [%e l] then
        let [%p (mkpatvar valN)] = 0 in
        let [%p (mkpatvar offN)] = [%e (mkident off)] + [%e l]
        and [%p (mkpatvar lenN)] = [%e (mkident len)] - [%e l]
        in match [%e (mkident valN)] with
      | [%p p] when true -> [%e next]
        | _ -> ()]
  | _, None -> failwith "No type to generate"

let generate_case (dat, res, off, len) case =
  match case.pc_lhs.ppat_desc with
  | Ppat_constant (Const_string (value, _)) ->
      let beh = [%expr [%e (mkident res)] := Some ([%e case.pc_rhs]); raise Exit] in
      List.map ~f:(fun flds -> parse_fields flds) (String.split ~on:';' value)
      |> List.fold_right ~init:beh ~f:(fun e acc ->
          match e with
          | (p, None, None) -> beh
          | (p, Some l, Some q) -> generate_field (dat, res, off, len) (p, l, q) acc
          | _ -> failwith "Wrong pattern type in bitmatch case")
    | _ -> failwith "Wrong pattern type in bitmatch case"

let generate_cases ident cases =
  let datN = mksym "data" and resN = mksym "result" in
  let offN = mksym "off" and lenN = mksym "len" in
  let offNN = mksym "off" and lenNN = mksym "len" in
  let stmts = List.fold ~init:[]
    ~f:(fun acc case -> acc @ [ generate_case (datN, resN, offNN, lenNN) case ])
    cases
  in
  let rec build_seq = function
    | [] -> failwith "Empty case list"
    | [hd] -> hd
    | hd :: tl -> Exp.sequence hd (build_seq tl)
  in
  let seq = build_seq stmts in
  let tuple = [%pat? ([%p (mkpatvar datN)], [%p (mkpatvar offN)], [%p (mkpatvar lenN)])] in
  [%expr
    let [%p tuple] = [%e ident] in
    let [%p (mkpatvar offNN)] = [%e (mkident offN)]
    and [%p (mkpatvar lenNN)] = [%e (mkident lenN)]
    in
    let [%p (mkpatvar resN)] = ref None in
    (try [%e seq];
    with | Exit -> ());
    match ![%e (mkident resN)] with
    | Some x -> x
    | None -> raise (Match_failure ("", 0, 0))]

let getenv_mapper argv =
  (* Our getenv_mapper only overrides the handling of expressions in the default mapper. *)
  { default_mapper with expr = fun mapper expr ->
    match expr with
    (* Is this an extension node? *)
    | { pexp_desc = Pexp_extension ({ txt = "bitstring"; loc }, pstr) } ->
        begin match pstr with
        (* Should have a single structure item, which is evaluation of a match expression *)
        | PStr [{ pstr_desc = Pstr_eval ( { pexp_loc = loc; pexp_desc =
          Pexp_match (ident, cases) }, _) }] -> generate_cases ident cases
        | _ ->
            raise (Location.Error (
              Location.error ~loc "[%getenv] accepts a string, e.g. [%getenv \"USER\"]"))
        end
    (* Delegate to the default mapper. *)
    | x -> default_mapper.expr mapper x;
  }

let () = register "getenv" getenv_mapper
