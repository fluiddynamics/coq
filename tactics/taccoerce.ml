(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Pp
open Util
open Errors
open Names
open Term
open Pattern
open Misctypes
open Genarg

exception CannotCoerceTo of string

let (wit_unit : (unit, unit, unit) Genarg.genarg_type) =
  Genarg.create_arg None "unit"

let (wit_constr_context : (Empty.t, Empty.t, constr) Genarg.genarg_type) =
  Genarg.create_arg None "constr_context"

(* includes idents known to be bound and references *)
let (wit_constr_under_binders : (Empty.t, Empty.t, constr_under_binders) Genarg.genarg_type) =
  Genarg.create_arg None "constr_under_binders"

module Value =
struct

type t = tlevel generic_argument

let rec normalize v =
  if has_type v (topwit wit_genarg) then
    normalize (out_gen (topwit wit_genarg) v)
  else v

let of_constr c = in_gen (topwit wit_constr) c

let to_constr v =
  let v = normalize v in
  if has_type v (topwit wit_constr) then
    let c = out_gen (topwit wit_constr) v in
    Some c
  else if has_type v (topwit wit_constr_under_binders) then
    let vars, c = out_gen (topwit wit_constr_under_binders) v in
    match vars with [] -> Some c | _ -> None
  else None

let of_int i = in_gen (topwit wit_int) i

let to_int v =
  let v = normalize v in
  if has_type v (topwit wit_int) then
    Some (out_gen (topwit wit_int) v)
  else None

let to_list v =
  let v = normalize v in
  try Some (fold_list0 (fun v accu -> v :: accu) v [])
  with Failure _ ->
    try Some (fold_list1 (fun v accu -> v :: accu) v [])
    with Failure _ ->
      None

end

let is_variable env id =
  List.mem id (Termops.ids_of_named_context (Environ.named_context env))

(* Transforms an id into a constr if possible, or fails with Not_found *)
let constr_of_id env id =
  Term.mkVar (let _ = Environ.lookup_named id env in id)

(* Gives the constr corresponding to a Constr_context tactic_arg *)
let coerce_to_constr_context v =
  let v = Value.normalize v in
  if has_type v (topwit wit_constr_context) then
    out_gen (topwit wit_constr_context) v
  else errorlabstrm "coerce_to_constr_context" (str "Not a context variable.")

(* Interprets an identifier which must be fresh *)
let coerce_to_ident fresh env v =
  let v = Value.normalize v in
  let fail () = raise (CannotCoerceTo "a fresh identifier") in
  if has_type v (topwit wit_intro_pattern) then
    match out_gen (topwit wit_intro_pattern) v with
    | _, IntroIdentifier id -> id
    | _ -> fail ()
  else match Value.to_constr v with
  | None -> fail ()
  | Some c ->
    (* We need it fresh for intro e.g. in "Tac H = clear H; intro H" *)
    if isVar c && not (fresh && is_variable env (destVar c)) then
      destVar c
    else fail ()

let coerce_to_intro_pattern env v =
  let v = Value.normalize v in
  if has_type v (topwit wit_intro_pattern) then
    snd (out_gen (topwit wit_intro_pattern) v)
  else match Value.to_constr v with
  | Some c when isVar c ->
      (* This happens e.g. in definitions like "Tac H = clear H; intro H" *)
      (* but also in "destruct H as (H,H')" *)
      IntroIdentifier (destVar c)
  | _ -> raise (CannotCoerceTo "an introduction pattern")

let coerce_to_hint_base v =
  let v = Value.normalize v in
  if has_type v (topwit wit_intro_pattern) then
    match out_gen (topwit wit_intro_pattern) v with
    | _, IntroIdentifier id -> Id.to_string id
    | _ -> raise (CannotCoerceTo "a hint base name")
  else raise (CannotCoerceTo "a hint base name")

let coerce_to_int v =
  let v = Value.normalize v in
  if has_type v (topwit wit_int) then
    out_gen (topwit wit_int) v
  else raise (CannotCoerceTo "an integer")

let coerce_to_constr env v =
  let v = Value.normalize v in
  if has_type v (topwit wit_intro_pattern) then
    match out_gen (topwit wit_intro_pattern) v with
    | _, IntroIdentifier id -> ([],constr_of_id env id)
    | _ -> raise Not_found
  else if has_type v (topwit wit_constr) then
    let c = out_gen (topwit wit_constr) v in
    ([], c)
  else if has_type v (topwit wit_constr_under_binders) then
    out_gen (topwit wit_constr_under_binders) v
  else raise Not_found

let coerce_to_closed_constr env v =
  let ids,c = coerce_to_constr env v in
  if not (List.is_empty ids) then raise Not_found;
  c

let coerce_to_evaluable_ref env v =
  let fail () = raise (CannotCoerceTo "an evaluable reference") in
  let v = Value.normalize v in
  if has_type v (topwit wit_intro_pattern) then
    match out_gen (topwit wit_intro_pattern) v with
    | _, IntroIdentifier id when List.mem id (Termops.ids_of_context env) -> EvalVarRef id
    | _ -> fail ()
  else
    let ev = match Value.to_constr v with
    | Some c when isConst c -> EvalConstRef (destConst c)
    | Some c when isVar c -> EvalVarRef (destVar c)
    | _ -> fail ()
    in
    if Tacred.is_evaluable env ev then ev else fail ()

let coerce_to_constr_list env v =
  let v = Value.to_list v in
  match v with
  | Some l ->
    let map v = coerce_to_closed_constr env v in
    List.map map l
  | None -> raise Not_found

let coerce_to_intro_pattern_list loc env v =
  match Value.to_list v with
  | None -> raise Not_found
  | Some l ->
    let map v = (loc, coerce_to_intro_pattern env v) in
    List.map map l

let coerce_to_hyp env v =
  let fail () = raise (CannotCoerceTo "a variable") in
  let v = Value.normalize v in
  if has_type v (topwit wit_intro_pattern) then
    match out_gen (topwit wit_intro_pattern) v with
    | _, IntroIdentifier id when is_variable env id -> id
    | _ -> fail ()
  else match Value.to_constr v with
  | Some c when isVar c -> destVar c
  | _ -> fail ()

let coerce_to_hyp_list env v =
  let v = Value.to_list v in
  match v with
  | Some l ->
    let map n = coerce_to_hyp env n in
    List.map map l
  | None -> raise Not_found

(* Interprets a qualified name *)
let coerce_to_reference env v =
  let v = Value.normalize v in
  match Value.to_constr v with
  | Some c ->
    begin
      try Globnames.global_of_constr c
      with Not_found -> raise (CannotCoerceTo "a reference")
    end
  | None -> raise (CannotCoerceTo "a reference")

let coerce_to_inductive v =
  match Value.to_constr v with
  | Some c when isInd c -> destInd c
  | _ -> raise (CannotCoerceTo "an inductive type")

(* Quantified named or numbered hypothesis or hypothesis in context *)
(* (as in Inversion) *)
let coerce_to_quantified_hypothesis v =
  let v = Value.normalize v in
  if has_type v (topwit wit_intro_pattern) then
    let v = out_gen (topwit wit_intro_pattern) v in
    match v with
    | _, IntroIdentifier id -> NamedHyp id
    | _ -> raise (CannotCoerceTo "a quantified hypothesis")
  else if has_type v (topwit wit_int) then
    AnonHyp (out_gen (topwit wit_int) v)
  else raise (CannotCoerceTo "a quantified hypothesis")

(* Quantified named or numbered hypothesis or hypothesis in context *)
(* (as in Inversion) *)
let coerce_to_decl_or_quant_hyp env v =
  let v = Value.normalize v in
  if has_type v (topwit wit_int) then
    AnonHyp (out_gen (topwit wit_int) v)
  else
    try
      let hyp = coerce_to_hyp env v in
      NamedHyp hyp
    with CannotCoerceTo _ ->
      raise (CannotCoerceTo "a declared or quantified hypothesis")

let coerce_to_int_or_var_list v =
  match Value.to_list v with
  | None -> raise Not_found
  | Some l ->
    let map n = ArgArg (coerce_to_int n) in
    List.map map l
