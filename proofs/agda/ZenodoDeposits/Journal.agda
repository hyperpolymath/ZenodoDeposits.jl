-- SPDX-License-Identifier: MPL-2.0
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
--
-- Safety of the ZenodoDeposits journal state machine.
--
-- `step` is imported from Transitions.agda, which is GENERATED from the Julia
-- table `ZenodoDeposits.TRANSITIONS`; the Julia test suite fails if it is
-- stale. The theorems below therefore hold for the exact table the Julia
-- journal uses. See proofs/agda/CORRESPONDENCE.adoc.
--
-- Method: each safety property is a *budget* argument. A budget b : State → ℕ
-- bounds how many events of one kind can still happen. If every single step
-- spends at most what it uses up (stepOK), then along any trace
--     (events emitted) + (budget left) ≤ (budget at the start).
-- stepOK is established for all 6 × 5 × 3 = 90 (state, action, outcome)
-- triples by a Boolean check that Agda evaluates (`checked-… = tt`), so a
-- change to the Julia table that breaks a property makes this file fail to
-- typecheck.

{-# OPTIONS --safe --without-K #-}
module ZenodoDeposits.Journal where

open import Data.Bool.Base using (Bool; true; false; T; _∧_)
open import Data.Unit.Base using (⊤; tt)
open import Data.Nat.Base using (ℕ; zero; suc; _+_; _≤_; _≤ᵇ_; z≤n; s≤s)
open import Data.Nat.Properties
  using (≤ᵇ⇒≤; +-assoc; +-monoʳ-≤; ≤-trans; ≤-refl; n≤0⇒n≡0; m≤m+n; m≤n+m; module ≤-Reasoning)
open import Data.List.Base using (List; []; _∷_; _++_)
open import Data.List.Properties using (++-assoc)
open import Data.Product.Base using (_×_; _,_; proj₁; proj₂)
open import Relation.Binary.PropositionalEquality using (_≡_; refl; cong; sym; trans; subst)

open import ZenodoDeposits.Transitions

------------------------------------------------------------------------
-- Finite enumeration: a Boolean check over every triple is sound.

data _∈_ {A : Set} (x : A) : List A → Set where
  here  : ∀ {xs} → x ∈ (x ∷ xs)
  there : ∀ {y xs} → x ∈ xs → x ∈ (y ∷ xs)

every : {A : Set} → List A → (A → Bool) → Bool
every []       p = true
every (x ∷ xs) p = p x ∧ every xs p

T∧ : ∀ a b → T (a ∧ b) → T a × T b
T∧ true  b t = tt , t
T∧ false b ()

every-sound : {A : Set} (xs : List A) (p : A → Bool) → T (every xs p) → ∀ {x} → x ∈ xs → T (p x)
every-sound (x ∷ xs) p t here      = proj₁ (T∧ (p x) (every xs p) t)
every-sound (x ∷ xs) p t (there m) = every-sound xs p (proj₂ (T∧ (p x) (every xs p) t)) m

state-listed : ∀ s → s ∈ allStates
state-listed empty             = here
state-listed create-uncertain  = there here
state-listed draft             = there (there here)
state-listed uploaded          = there (there (there here))
state-listed publish-uncertain = there (there (there (there here)))
state-listed published         = there (there (there (there (there here))))

action-listed : ∀ a → a ∈ allActions
action-listed create    = here
action-listed recover   = there here
action-listed upload    = there (there here)
action-listed publish   = there (there (there here))
action-listed reconcile = there (there (there (there here)))

outcome-listed : ∀ o → o ∈ allOutcomes
outcome-listed ok        = here
outcome-listed rejected  = there here
outcome-listed ambiguous = there (there here)

everyTriple : (State → Action → Outcome → Bool) → Bool
everyTriple p = every allStates (λ s → every allActions (λ a → every allOutcomes (λ o → p s a o)))

everyTriple-sound : ∀ p → T (everyTriple p) → ∀ s a o → T (p s a o)
everyTriple-sound p t s a o =
  every-sound allOutcomes (λ o → p s a o)
    (every-sound allActions (λ a → every allOutcomes (λ o → p s a o))
      (every-sound allStates (λ s → every allActions (λ a → every allOutcomes (λ o → p s a o)))
        t (state-listed s))
      (action-listed a))
    (outcome-listed o)

------------------------------------------------------------------------
-- Traces: a journal run is a list of (action, outcome) pairs. Every state
-- the Julia journal persists — including the write-ahead record, which is
-- `proj₁ (step s a ambiguous)` — is `fin s₀ t` for some trace t.

Trace : Set
Trace = List (Action × Outcome)

fin : State → Trace → State
fin s []              = s
fin s ((a , o) ∷ t) = fin (proj₁ (step s a o)) t

evs : State → Trace → List Event
evs s []              = []
evs s ((a , o) ∷ t) = proj₂ (step s a o) ++ evs (proj₁ (step s a o)) t

-- Resuming from a persisted state is continuing the same trace.
fin-++ : ∀ s t₁ t₂ → fin s (t₁ ++ t₂) ≡ fin (fin s t₁) t₂
fin-++ s []              t₂ = refl
fin-++ s ((a , o) ∷ t₁) t₂ = fin-++ (proj₁ (step s a o)) t₁ t₂

evs-++ : ∀ s t₁ t₂ → evs s (t₁ ++ t₂) ≡ evs s t₁ ++ evs (fin s t₁) t₂
evs-++ s []              t₂ = refl
evs-++ s ((a , o) ∷ t₁) t₂ =
  trans (cong (proj₂ (step s a o) ++_) (evs-++ (proj₁ (step s a o)) t₁ t₂))
        (sym (++-assoc (proj₂ (step s a o)) (evs (proj₁ (step s a o)) t₁) _))

------------------------------------------------------------------------
-- Counting events.

cnt : (Event → ℕ) → List Event → ℕ
cnt f []       = 0
cnt f (e ∷ es) = f e + cnt f es

cnt-++ : ∀ f xs ys → cnt f (xs ++ ys) ≡ cnt f xs + cnt f ys
cnt-++ f []       ys = refl
cnt-++ f (x ∷ xs) ys = trans (cong (f x +_) (cnt-++ f xs ys)) (sym (+-assoc (f x) (cnt f xs) (cnt f ys)))

------------------------------------------------------------------------
-- The budget argument, generic in the event weight f and the budget b.

module Budgeted (f : Event → ℕ) (b : State → ℕ)
  (stepOK : ∀ s a o → cnt f (proj₂ (step s a o)) + b (proj₁ (step s a o)) ≤ b s) where

  fold : ∀ s t → cnt f (evs s t) + b (fin s t) ≤ b s
  fold s []              = ≤-refl
  fold s ((a , o) ∷ t) = begin
      cnt f (es ++ evs s′ t) + b (fin s′ t)
    ≡⟨ cong (_+ b (fin s′ t)) (cnt-++ f es (evs s′ t)) ⟩
      (cnt f es + cnt f (evs s′ t)) + b (fin s′ t)
    ≡⟨ +-assoc (cnt f es) (cnt f (evs s′ t)) (b (fin s′ t)) ⟩
      cnt f es + (cnt f (evs s′ t) + b (fin s′ t))
    ≤⟨ +-monoʳ-≤ (cnt f es) (fold s′ t) ⟩
      cnt f es + b s′
    ≤⟨ stepOK s a o ⟩
      b s
    ∎
    where
      open ≤-Reasoning
      s′ = proj₁ (step s a o)
      es = proj₂ (step s a o)

  -- Events along a trace never exceed the starting budget.
  bounded : ∀ s t → cnt f (evs s t) ≤ b s
  bounded s t = ≤-trans (m≤m+n (cnt f (evs s t)) (b (fin s t))) (fold s t)

  -- From a state with no budget left, no such event can ever happen.
  exhausted : ∀ s → b s ≡ 0 → ∀ t → cnt f (evs s t) ≡ 0
  exhausted s eq t = n≤0⇒n≡0 (subst (cnt f (evs s t) ≤_) eq (bounded s t))

  -- With a budget of at most one: once the event has happened, a resumed
  -- run from the persisted state can never emit it again.
  once : (∀ s → b s ≤ 1) → ∀ s₀ t₁ t₂ → 1 ≤ cnt f (evs s₀ t₁) → cnt f (evs (fin s₀ t₁) t₂) ≡ 0
  once b≤1 s₀ t₁ t₂ happened = exhausted (fin s₀ t₁) (spent happened (≤-trans (fold s₀ t₁) (b≤1 s₀))) t₂
    where
      spent : ∀ {p r} → 1 ≤ p → p + r ≤ 1 → r ≡ 0
      spent {suc p} {r} (s≤s z≤n) (s≤s h) = n≤0⇒n≡0 (≤-trans (m≤n+m r p) h)

-- stepOK from a Boolean check over all 90 triples.
stepOK-from : (f : Event → ℕ) (b : State → ℕ) →
  T (everyTriple (λ s a o → (cnt f (proj₂ (step s a o)) + b (proj₁ (step s a o))) ≤ᵇ b s)) →
  ∀ s a o → cnt f (proj₂ (step s a o)) + b (proj₁ (step s a o)) ≤ b s
stepOK-from f b t s a o =
  ≤ᵇ⇒≤ (cnt f (proj₂ (step s a o)) + b (proj₁ (step s a o))) (b s)
    (everyTriple-sound (λ s a o → (cnt f (proj₂ (step s a o)) + b (proj₁ (step s a o))) ≤ᵇ b s) t s a o)

------------------------------------------------------------------------
-- Event weights and budgets.

publishes creates mints : Event → ℕ
publishes sent-publish = 1
publishes _            = 0
creates sent-create = 1
creates _           = 0
mints minted = 1
mints _      = 0

-- A publish request may still be sent only before one has been sent.
publish-budget : State → ℕ
publish-budget empty             = 1
publish-budget create-uncertain  = 1
publish-budget draft             = 1
publish-budget uploaded          = 1
publish-budget publish-uncertain = 0
publish-budget published         = 0

-- A create request may be sent only from the empty journal.
create-budget : State → ℕ
create-budget empty = 1
create-budget _     = 0

-- A DOI is minted (observed published) at most once.
mint-budget : State → ℕ
mint-budget published = 0
mint-budget _         = 1

-- These three checks are evaluated by Agda over the generated table. Each
-- fails to typecheck (`tt` is not of type ⊥) if the table breaks the budget.
checked-publish : T (everyTriple (λ s a o → (cnt publishes (proj₂ (step s a o)) + publish-budget (proj₁ (step s a o))) ≤ᵇ publish-budget s))
checked-publish = tt

checked-create : T (everyTriple (λ s a o → (cnt creates (proj₂ (step s a o)) + create-budget (proj₁ (step s a o))) ≤ᵇ create-budget s))
checked-create = tt

checked-mint : T (everyTriple (λ s a o → (cnt mints (proj₂ (step s a o)) + mint-budget (proj₁ (step s a o))) ≤ᵇ mint-budget s))
checked-mint = tt

module P = Budgeted publishes publish-budget (stepOK-from publishes publish-budget checked-publish)
module C = Budgeted creates create-budget (stepOK-from creates create-budget checked-create)
module M = Budgeted mints mint-budget (stepOK-from mints mint-budget checked-mint)

publish-budget≤1 : ∀ s → publish-budget s ≤ 1
publish-budget≤1 empty             = s≤s z≤n
publish-budget≤1 create-uncertain  = s≤s z≤n
publish-budget≤1 draft             = s≤s z≤n
publish-budget≤1 uploaded          = s≤s z≤n
publish-budget≤1 publish-uncertain = z≤n
publish-budget≤1 published         = z≤n

create-budget≤1 : ∀ s → create-budget s ≤ 1
create-budget≤1 empty             = s≤s z≤n
create-budget≤1 create-uncertain  = z≤n
create-budget≤1 draft             = z≤n
create-budget≤1 uploaded          = z≤n
create-budget≤1 publish-uncertain = z≤n
create-budget≤1 published         = z≤n

mint-budget≤1 : ∀ s → mint-budget s ≤ 1
mint-budget≤1 empty             = s≤s z≤n
mint-budget≤1 create-uncertain  = s≤s z≤n
mint-budget≤1 draft             = s≤s z≤n
mint-budget≤1 uploaded          = s≤s z≤n
mint-budget≤1 publish-uncertain = s≤s z≤n
mint-budget≤1 published         = z≤n

------------------------------------------------------------------------
-- Theorems.

-- (1) No trace, from any state (so in particular from `empty`), contains two
--     publish requests; likewise for create requests and minted DOIs.
at-most-one-publish : ∀ s t → cnt publishes (evs s t) ≤ 1
at-most-one-publish s t = ≤-trans (P.bounded s t) (publish-budget≤1 s)

at-most-one-create : ∀ s t → cnt creates (evs s t) ≤ 1
at-most-one-create s t = ≤-trans (C.bounded s t) (create-budget≤1 s)

at-most-one-mint : ∀ s t → cnt mints (evs s t) ≤ 1
at-most-one-mint s t = ≤-trans (M.bounded s t) (mint-budget≤1 s)

-- (2) Resume never re-publishes: if a run up to some persisted state sent a
--     publish request, every continuation from that state sends none.
resume-never-republishes : ∀ s₀ t₁ t₂ →
  1 ≤ cnt publishes (evs s₀ t₁) → cnt publishes (evs (fin s₀ t₁) t₂) ≡ 0
resume-never-republishes = P.once publish-budget≤1

resume-never-recreates : ∀ s₀ t₁ t₂ →
  1 ≤ cnt creates (evs s₀ t₁) → cnt creates (evs (fin s₀ t₁) t₂) ≡ 0
resume-never-recreates = C.once create-budget≤1

-- The same, stated for the persisted states themselves: resuming from the
-- write-ahead state `publish-uncertain` or from `published` never sends a
-- publish request, whatever happens next.
no-publish-after-publish-uncertain : ∀ t → cnt publishes (evs publish-uncertain t) ≡ 0
no-publish-after-publish-uncertain = P.exhausted publish-uncertain refl

no-publish-after-published : ∀ t → cnt publishes (evs published t) ≡ 0
no-publish-after-published = P.exhausted published refl

no-create-after-create-uncertain : ∀ t → cnt creates (evs create-uncertain t) ≡ 0
no-create-after-create-uncertain = C.exhausted create-uncertain refl

-- (3) Published is terminal: every action and outcome leaves it unchanged
--     and emits nothing, so every run from it stays there silently.
published-terminal : ∀ a o → step published a o ≡ (published , [])
published-terminal a o = refl

published-stays : ∀ t → fin published t ≡ published
published-stays []              = refl
published-stays ((a , o) ∷ t) = published-stays t

published-silent : ∀ t → evs published t ≡ []
published-silent []              = refl
published-silent ((a , o) ∷ t) = published-silent t

-- (4) Write-ahead correspondence: the state the Julia journal persists
--     before sending a create or publish request is the model's
--     ambiguous-outcome state.
write-ahead-create : proj₁ (step empty create ambiguous) ≡ create-uncertain
write-ahead-create = refl

write-ahead-publish : proj₁ (step uploaded publish ambiguous) ≡ publish-uncertain
write-ahead-publish = refl

-- (5) Sanity: the happy path reaches `published` with exactly one create,
--     one publish and one mint (the model is not vacuously safe).
happy-path : Trace
happy-path = (create , ok) ∷ (upload , ok) ∷ (publish , ok) ∷ []

happy-path-publishes : fin empty happy-path ≡ published
happy-path-publishes = refl

happy-path-events : evs empty happy-path ≡ sent-create ∷ sent-publish ∷ minted ∷ []
happy-path-events = refl

-- Lost publish response, then reconciliation: still one publish request.
lost-publish : Trace
lost-publish = (create , ok) ∷ (upload , ok) ∷ (publish , ambiguous) ∷ (reconcile , rejected) ∷ (reconcile , ok) ∷ []

lost-publish-events : evs empty lost-publish ≡ sent-create ∷ sent-publish ∷ minted ∷ []
lost-publish-events = refl
