module Build where

import Ansi.Log
import Date exposing (Date)
import Date.Format
import Debug
import Effects exposing (Effects)
import EventSource exposing (EventSource)
import Html exposing (Html)
import Html.Events exposing (onClick, on)
import Html.Attributes exposing (action, class, classList, href, id, method, title)
import Http
import Json.Decode exposing ((:=))
import Task exposing (Task)
import Time exposing (Time)

import Concourse.Build exposing (Build)
import Concourse.BuildEvents exposing (BuildEvent)
import Concourse.BuildPlan exposing (BuildPlan)
import Concourse.BuildResources exposing (BuildResources)
import Concourse.BuildStatus exposing (BuildStatus)
import Concourse.Metadata exposing (Metadata)
import Concourse.Pagination exposing (Paginated)
import Concourse.Version exposing (Version)
import Duration exposing (Duration)
import Scroll
import StepTree exposing (StepTree)

type alias Model =
  { redirect : Signal.Address String
  , actions : Signal.Address Action
  , buildId : Int
  , errors : Maybe Ansi.Log.Model
  , steps : Maybe StepTree.Model
  , build : Maybe Build
  , history : Maybe (List Build)
  , eventSource : Maybe EventSource
  , stepState : StepRenderingState
  , status : BuildStatus
  , autoScroll : Bool
  , now : Time.Time
  , duration : BuildDuration
  }

type alias BuildDuration =
  { startedAt : Maybe Date
  , finishedAt : Maybe Date
  }

type StepRenderingState
  = StepsLoading
  | StepsLiveUpdating
  | StepsComplete
  | LoginRequired

type Action
  = Noop
  | PlanAndResourcesFetched (Result Http.Error (BuildPlan, BuildResources))
  | BuildFetched (Result Http.Error Build)
  | BuildHistoryFetched (Result Http.Error (Paginated Build))
  | BuildEventsListening EventSource
  | BuildEventsAction Concourse.BuildEvents.Action
  | BuildEventsClosed
  | ScrollTick
  | ScrollFromBottom Int
  | ScrollBuilds (Float, Float)
  | StepTreeAction StepTree.Action
  | ClockTick Time.Time
  | AbortBuild
  | BuildAborted (Result Http.Error ())
  | RevealCurrentBuildInHistory

init : Signal.Address String -> Signal.Address Action -> Int -> (Model, Effects Action)
init redirect actions buildId =
  let
    model =
      { redirect = redirect
      , actions = actions
      , buildId = buildId
      , errors = Nothing
      , steps = Nothing
      , build = Nothing
      , history = Nothing
      , eventSource = Nothing
      , stepState = StepsLoading
      , autoScroll = True
      , status = Concourse.BuildStatus.Pending
      , now = 0
      , duration = BuildDuration Nothing Nothing
      }
  in
    (model, fetchBuild 0 buildId)

update : Action -> Model -> (Model, Effects Action)
update action model =
  case action of
    Noop ->
      (model, Effects.none)

    ScrollTick ->
      if model.stepState == StepsLiveUpdating && model.autoScroll then
        (model, scrollToBottom)
      else
        (model, Effects.none)

    ScrollFromBottom fromBottom ->
      ({ model | autoScroll = fromBottom == 0 }, Effects.none)

    AbortBuild ->
      (model, abortBuild model.buildId)

    BuildAborted (Ok ()) ->
      (model, Effects.none)

    BuildAborted (Err (Http.BadResponse 401 _)) ->
      (model, redirectToLogin model)

    BuildAborted (Err err) ->
      Debug.log ("failed to abort build: " ++ toString err) <|
        (model, Effects.none)

    BuildFetched (Ok build) ->
      handleBuildFetched build model

    BuildFetched (Err err) ->
      Debug.log ("failed to fetch build: " ++ toString err) <|
        (model, Effects.none)

    PlanAndResourcesFetched (Err (Http.BadResponse 404 _)) ->
      (model , subscribeToEvents model.buildId model.actions)

    PlanAndResourcesFetched (Err err) ->
      Debug.log ("failed to fetch plan: " ++ toString err) <|
        (model, Effects.none)

    PlanAndResourcesFetched (Ok (plan, resources)) ->
      ( { model | steps = Just (StepTree.init resources plan) }
      , subscribeToEvents model.buildId model.actions
      )

    BuildHistoryFetched (Err err) ->
      Debug.log ("failed to fetch build history: " ++ toString err) <|
        (model, Effects.none)

    BuildHistoryFetched (Ok history) ->
      handleHistoryFetched history model

    RevealCurrentBuildInHistory ->
      (model, scrollToCurrentBuildInHistory)

    BuildEventsListening es ->
      ({ model | eventSource = Just es }, Effects.none)

    BuildEventsAction action ->
      handleEventsAction action model

    BuildEventsClosed ->
      ({ model | eventSource = Nothing }, Effects.none)

    StepTreeAction action ->
      ( { model | steps = Maybe.map (StepTree.update action) model.steps }
      , Effects.none
      )

    ScrollBuilds (0, deltaY) ->
      (model, scrollBuilds deltaY)

    ScrollBuilds (deltaX, _) ->
      (model, scrollBuilds -deltaX)

    ClockTick now ->
      ({ model | now = now }, Effects.none)

handleBuildFetched : Build -> Model -> (Model, Effects Action)
handleBuildFetched build model =
  let
    pending =
      build.status == Concourse.BuildStatus.Pending

    stepState =
      if Concourse.BuildStatus.isRunning build.status then
        StepsLiveUpdating
      else
        StepsLoading

    fetch =
      if pending then
        fetchBuild Time.second model.buildId
      else if build.job /= Nothing then
        fetchBuildPlanAndResources model.buildId
      else
        fetchBuildPlan model.buildId

    fetchHistory =
      case (model.build, build.job) of
        (Nothing, Just job) ->
          fetchBuildHistory job Nothing

        _ ->
          Effects.none
  in
    ( { model | build = Just build
              , status = build.status
              , stepState = stepState }
    , Effects.batch [fetch, fetchHistory]
    )

handleHistoryFetched : Paginated Build -> Model -> (Model, Effects Action)
handleHistoryFetched history model =
  let
    builds =
      List.append (Maybe.withDefault [] model.history) history.content

    withBuilds =
      { model | history = Just builds }

    loadedCurrentBuild =
      List.any ((==) model.buildId << .id) history.content

    scrollToCurrent =
      if loadedCurrentBuild then
        -- deferred so that UI will render build first, so we can scroll to it
        Effects.tick (always RevealCurrentBuildInHistory)
      else
        Effects.none
  in
    case (history.pagination.nextPage, model.build `Maybe.andThen` .job) of
      (Nothing, _) ->
        (withBuilds, scrollToCurrent)

      (Just page, Just job) ->
        (withBuilds, Effects.batch [fetchBuildHistory job (Just page), scrollToCurrent])

      (Just url, Nothing) ->
        Debug.crash "impossible"

handleEventsAction : Concourse.BuildEvents.Action -> Model -> (Model, Effects Action)
handleEventsAction action model =
  case action of
    Concourse.BuildEvents.Opened ->
      (model, scrollToBottom)

    Concourse.BuildEvents.Errored ->
      let
        newState =
          case model.stepState of
            -- if we're loading and the event source errors, assume we're not
            -- logged in (there's no way to actually tell)
            StepsLoading ->
              LoginRequired

            -- closing the event source causes an error to come in, so ignore
            -- it since that means everything actually worked
            StepsComplete ->
              model.stepState

            -- getting an error in the middle could just be the ATC going away
            -- (i.e. during a deploy). ignore it and let the browser
            -- auto-reconnect
            StepsLiveUpdating ->
              model.stepState

            -- shouldn't ever happen, but...
            LoginRequired ->
              model.stepState
      in
        ({ model | stepState = newState }, Effects.none)

    Concourse.BuildEvents.Event (Ok event) ->
      let
        (returnedModel, returnedEvent) = handleEvent event model
      in
        (returnedModel, Effects.batch [returnedEvent, scrollToBottom])

    Concourse.BuildEvents.Event (Err err) ->
      (model, Debug.log err Effects.none)

    Concourse.BuildEvents.End ->
      case model.eventSource of
        Just es ->
          ({ model | stepState = StepsComplete }, closeEvents es)

        Nothing ->
          (model, Effects.none)

handleEvent : Concourse.BuildEvents.BuildEvent -> Model -> (Model, Effects Action)
handleEvent event model =
  case event of
    Concourse.BuildEvents.Log origin output ->
      ( updateStep origin.id (setRunning << appendStepLog output) model
      , Effects.tick (always ScrollTick)
      )

    Concourse.BuildEvents.Error origin message ->
      ( updateStep origin.id (setStepError message) model
      , Effects.none
      )

    Concourse.BuildEvents.InitializeTask origin ->
      ( updateStep origin.id setRunning model
      , Effects.none
      )

    Concourse.BuildEvents.StartTask origin ->
      ( updateStep origin.id setRunning model
      , Effects.none
      )

    Concourse.BuildEvents.FinishTask origin exitStatus ->
      ( updateStep origin.id (finishStep exitStatus) model
      , Effects.none
      )

    Concourse.BuildEvents.InitializeGet origin ->
      ( updateStep origin.id setRunning model
      , Effects.none
      )

    Concourse.BuildEvents.FinishGet origin exitStatus version metadata ->
      ( updateStep origin.id (finishStep exitStatus << setResourceInfo version metadata) model
      , Effects.none
      )

    Concourse.BuildEvents.InitializePut origin ->
      ( updateStep origin.id setRunning model
      , Effects.none
      )

    Concourse.BuildEvents.FinishPut origin exitStatus version metadata ->
      ( updateStep origin.id (finishStep exitStatus << setResourceInfo version metadata) model
      , Effects.none
      )

    Concourse.BuildEvents.BuildStatus status date ->
      let
        updated =
          if not <| Concourse.BuildStatus.isRunning status then
            { model | steps = Maybe.map (StepTree.update StepTree.Finished) model.steps }
          else
            model
      in
        ( updateStartFinishAt status date <|
            case updated.stepState of
              StepsLiveUpdating ->
                { updated | status = status }

              _ ->
                updated
        , Effects.none
        )

    Concourse.BuildEvents.BuildError message ->
      ( { model |
          errors =
            Just <|
              Ansi.Log.update message <|
                Maybe.withDefault (Ansi.Log.init Ansi.Log.Cooked) model.errors
        }
      , Effects.none
      )

updateStartFinishAt : BuildStatus -> Date -> Model -> Model
updateStartFinishAt status date model =
  let
    duration = model.duration
  in
    case status of
      Concourse.BuildStatus.Started ->
        { model | duration = { duration | startedAt = Just date } }

      _ ->
        { model | duration = { duration | finishedAt = Just date } }

abortBuild : Int -> Effects Action
abortBuild buildId =
  Concourse.Build.abort buildId
    |> Task.toResult
    |> Task.map BuildAborted
    |> Effects.task

updateStep : StepTree.StepID -> (StepTree -> StepTree) -> Model -> Model
updateStep id update model =
  { model | steps = Maybe.map (StepTree.updateAt id update) model.steps }

setRunning : StepTree -> StepTree
setRunning = setStepState StepTree.StepStateRunning

appendStepLog : String -> StepTree -> StepTree
appendStepLog output tree =
  StepTree.map (\step -> { step | log = Ansi.Log.update output step.log }) tree

setStepError : String -> StepTree -> StepTree
setStepError message tree =
  StepTree.map
    (\step ->
      { step
      | state = StepTree.StepStateErrored
      , error = Just message
      })
    tree

finishStep : Int -> StepTree -> StepTree
finishStep exitStatus tree =
  let
    stepState =
      if exitStatus == 0 then
        StepTree.StepStateSucceeded
      else
        StepTree.StepStateFailed
  in
    setStepState stepState tree

setResourceInfo : Version -> Metadata -> StepTree -> StepTree
setResourceInfo version metadata tree =
  StepTree.map (\step -> { step | version = Just version, metadata = metadata }) tree

setStepState : StepTree.StepState -> StepTree -> StepTree
setStepState state tree =
  let
    autoCollapse = state == StepTree.StepStateSucceeded
  in
    StepTree.map (\step ->
      let
        expanded =
          if autoCollapse then
            Just <| Maybe.withDefault False step.expanded
          else
            step.expanded
      in
        { step
        | state = state
        , expanded = expanded
        }) tree

view : Signal.Address Action -> Model -> Html
view actions model =
  case (model.build, model.steps) of
    (Just build, Just root) ->
      Html.div []
        [ viewBuildHeader actions build model.status model.now model.duration (Maybe.withDefault [] model.history)
        , Html.div (id "build-body" :: paddingClass build)
            [ case model.stepState of
                StepsLoading ->
                  loadingIndicator

                StepsLiveUpdating ->
                  viewSteps actions model.errors build root

                StepsComplete ->
                  viewSteps actions model.errors build root

                LoginRequired ->
                  viewLoginButton build
            ]
        ]

    (Just build, Nothing) ->
      Html.div []
        [ viewBuildHeader actions build model.status model.now model.duration (Maybe.withDefault [] model.history)
        , Html.div (id "build-body" :: paddingClass build)
            [Html.div [class "steps"] [viewErrors model.errors]]
        ]

    _ ->
      loadingIndicator

loadingIndicator : Html
loadingIndicator =
  Html.div [class "steps"]
    [ Html.div [class "build-step"]
        [ Html.div [class "header"]
            [ Html.i [class "left fa fa-fw fa-spin fa-circle-o-notch"] []
            , Html.h3 [] [Html.text "loading"]
            ]
        ]
    ]

viewSteps : Signal.Address Action -> Maybe Ansi.Log.Model -> Build -> StepTree.Model -> Html
viewSteps actions errors build root =
  Html.div [class "steps"]
    [ viewErrors errors
    , StepTree.view (Signal.forwardTo actions StepTreeAction) root
    ]

viewErrors : Maybe Ansi.Log.Model -> Html
viewErrors errors =
  case errors of
    Nothing ->
      Html.div [] []

    Just log ->
      Html.div [class "build-step"]
        [ Html.div [class "header"]
            [ Html.i [class "left fa fa-fw fa-exclamation-triangle"] []
            , Html.h3 [] [Html.text "error"]
            ]
        , Html.div [class "step-body build-errors-body"] [Ansi.Log.view log]
        ]

viewLoginButton : Build -> Html
viewLoginButton build =
  Html.form
    [ class "build-login"
    , Html.Attributes.method "get"
    , Html.Attributes.action "/login"
    ]
    [ Html.input
        [ Html.Attributes.type' "submit"
        , Html.Attributes.value "log in to view"
        ] []
    , Html.input
        [ Html.Attributes.type' "hidden"
        , Html.Attributes.name "redirect"
        , Html.Attributes.value (Concourse.Build.url build)
        ] []
    ]

paddingClass : Build -> List Html.Attribute
paddingClass build =
  case build.job of
    Just _ ->
      []

    _ ->
      [class "build-body-noSubHeader"]

viewBuildHeader : Signal.Address Action -> Build -> BuildStatus -> Time.Time -> BuildDuration -> List Build -> Html
viewBuildHeader actions build status now duration history =
  let
    triggerButton =
      case build.job of
        Just {name, pipelineName} ->
          let
            actionUrl = "/pipelines/" ++ pipelineName ++ "/jobs/" ++ name ++ "/builds"
          in
            Html.form
              [class "trigger-build", method "post", action (actionUrl)]
              [Html.button [class "build-action fr"] [Html.i [class "fa fa-plus-circle"] []]]

        _ ->
          Html.div [] []

    abortButton =
      if Concourse.BuildStatus.isRunning status then
        Html.span
          [class "build-action build-action-abort fr", onClick actions AbortBuild]
          [Html.i [class "fa fa-times-circle"] []]
      else
        Html.span [] []

    buildTitle = case build.job of
      Just {name, pipelineName} ->
        Html.a [href ("/pipelines/" ++ pipelineName ++ "/jobs/" ++ name)]
          [Html.text (name ++ " #" ++ build.name)]

      _ ->
        Html.text ("build #" ++ toString build.id)
  in
    Html.div [id "page-header", class (Concourse.BuildStatus.show status)]
      [ Html.div [class "build-header"]
          [ Html.div [class "build-actions fr"] [triggerButton, abortButton]
          , Html.h1 [] [buildTitle]
          , viewBuildDuration now duration
          ]
      , Html.ul
          [ on "mousewheel" decodeScrollEvent (scrollEvent actions)
          , id "builds"
          ]
          (List.map (viewHistory build status) history)
      ]

viewHistory : Build -> BuildStatus -> Build -> Html
viewHistory currentBuild currentStatus build =
  Html.li
    [ classList
        [ ( if build.name == currentBuild.name then
              Concourse.BuildStatus.show currentStatus
            else
              Concourse.BuildStatus.show build.status
          , True
          )
        , ("current", build.name == currentBuild.name)
        ]
    ]
    [Html.a [href (Concourse.Build.url build)] [Html.text (build.name)]]

viewBuildDuration : Time.Time -> BuildDuration -> Html
viewBuildDuration now duration =
  Html.dl [class "build-times"] <|
    case (duration.startedAt, duration.finishedAt) of
      (Nothing, _) ->
        []

      (Just startedAt, Nothing) ->
        labeledRelativeDate "started" now startedAt

      (Just startedAt, Just finishedAt) ->
        let
          durationElmIssue = -- https://github.com/elm-lang/elm-compiler/issues/1223
            Duration.between (Date.toTime startedAt) (Date.toTime finishedAt)
        in
          labeledRelativeDate "started" now startedAt ++
            labeledRelativeDate "finished" now finishedAt ++
            labeledDuration "duration" durationElmIssue

durationTitle : Date -> List Html -> Html
durationTitle date content =
  Html.div [title (Date.Format.format "%b" date)] content

labeledRelativeDate : String -> Time -> Date -> List Html
labeledRelativeDate label now date =
  let
    ago = Duration.between (Date.toTime date) now
  in
    [ Html.dt [] [Html.text label]
    , Html.dd
        [title (Date.Format.format "%b %d %Y %I:%M:%S %p" date)]
        [Html.span [] [Html.text (Duration.format ago ++ " ago")]]
    ]

labeledDuration : String -> Duration ->  List Html
labeledDuration label duration =
  [ Html.dt [] [Html.text label]
  , Html.dd [] [Html.span [] [Html.text (Duration.format duration)]]
  ]

scrollEvent : Signal.Address Action -> (Float, Float) -> Signal.Message
scrollEvent actions delta =
  Signal.message actions (ScrollBuilds delta)

decodeScrollEvent : Json.Decode.Decoder (Float, Float)
decodeScrollEvent =
  Json.Decode.object2 (,)
    ("deltaX" := Json.Decode.float)
    ("deltaY" := Json.Decode.float)

fetchBuild : Time -> Int -> Effects Action
fetchBuild delay buildId =
  Task.sleep delay `Task.andThen` (always <| Concourse.Build.fetch buildId)
    |> Task.toResult
    |> Task.map BuildFetched
    |> Effects.task

fetchBuildPlanAndResources : Int -> Effects Action
fetchBuildPlanAndResources buildId =
  Task.map2 (,) (Concourse.BuildPlan.fetch buildId) (Concourse.BuildResources.fetch buildId)
    |> Task.toResult
    |> Task.map PlanAndResourcesFetched
    |> Effects.task

fetchBuildPlan : Int -> Effects Action
fetchBuildPlan buildId =
  Task.map (flip (,) Concourse.BuildResources.empty) (Concourse.BuildPlan.fetch buildId)
    |> Task.toResult
    |> Task.map PlanAndResourcesFetched
    |> Effects.task

fetchBuildHistory : Concourse.Build.Job -> Maybe Concourse.Pagination.Page -> Effects Action
fetchBuildHistory job page =
  Concourse.Build.fetchJobBuilds job page
    |> Task.toResult
    |> Task.map BuildHistoryFetched
    |> Effects.task

subscribeToEvents : Int -> Signal.Address Action -> Effects Action
subscribeToEvents build actions =
  Concourse.BuildEvents.subscribe build (Signal.forwardTo actions BuildEventsAction)
    |> Task.map BuildEventsListening
    |> Effects.task

closeEvents : EventSource.EventSource -> Effects Action
closeEvents eventSource =
  EventSource.close eventSource
    |> Task.map (always BuildEventsClosed)
    |> Effects.task

scrollToBottom : Effects Action
scrollToBottom =
  Scroll.toBottom
    |> Task.map (always Noop)
    |> Effects.task

scrollBuilds : Float -> Effects Action
scrollBuilds delta =
  Scroll.scroll "builds" delta
    |> Task.map (always Noop)
    |> Effects.task

scrollToCurrentBuildInHistory : Effects Action
scrollToCurrentBuildInHistory =
  Scroll.scrollIntoView "#builds .current"
    |> Task.map (always Noop)
    |> Effects.task

redirectToLogin : Model -> Effects Action
redirectToLogin model =
  Signal.send model.redirect "/login"
    |> Task.map (always Noop)
    |> Effects.task
