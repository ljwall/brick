module Brick.Main
  ( App(..)
  , defaultMain
  , defaultMainWithVty

  , EventM
  , Next(..)
  , viewportScroll
  , ViewportScroll(scrollBy, scrollPage, scrollToBeginning, scrollToEnd)

  , simpleMain

  , supplyVtyEvents
  , withVty
  , runVty

  , neverShowCursor
  , showFirstCursor
  )
where

import Control.Exception (finally)
import Control.Monad (forever)
import Control.Monad.Trans.State
import Control.Concurrent (forkIO, Chan, newChan, readChan, writeChan)
import Data.Default
import Data.Monoid
import Data.Maybe (listToMaybe)
import qualified Data.Map as M
import Graphics.Vty
  ( Vty
  , Picture(..)
  , Cursor(..)
  , Event(..)
  , Attr
  , update
  , outputIface
  , displayBounds
  , shutdown
  , nextEvent
  , mkVty
  )

import Brick.Widgets.Core (Widget)
import Brick.Widgets.Internal (renderFinal, RenderState(..), ScrollRequest(..), Direction(..))
import Brick.Core (Location(..), CursorLocation(..), Name(..))
import Brick.AttrMap

data Next a = Continue a
            | Shutdown a

data App a e =
    App { appDraw :: a -> [Widget]
        , appChooseCursor :: a -> [CursorLocation] -> Maybe CursorLocation
        , appHandleEvent :: e -> a -> EventM (Next a)
        , appAttrMap :: a -> AttrMap
        }

instance Default (App a e) where
    def = App { appDraw = const def
              , appChooseCursor = neverShowCursor
              , appHandleEvent = const (return . Continue)
              , appAttrMap = const def
              }

type EventM a = StateT EventState IO a

type EventState = [(Name, ScrollRequest)]

defaultMain :: App a Event -> a -> IO a
defaultMain = defaultMainWithVty (mkVty def)

simpleMain :: [(AttrName, Attr)] -> [Widget] -> IO ()
simpleMain attrs ls =
    let app = def { appDraw = const ls
                  , appHandleEvent = const (return . Shutdown)
                  , appAttrMap = const $ attrMap def attrs
                  }
    in defaultMain app ()

defaultMainWithVty :: IO Vty -> App a Event -> a -> IO a
defaultMainWithVty buildVty app initialAppState = do
    let initialRS = RS M.empty mempty
    chan <- newChan
    withVty buildVty $ \vty -> do
        forkIO $ supplyVtyEvents vty id chan
        runVty vty chan app initialAppState initialRS

supplyVtyEvents :: Vty -> (Event -> e) -> Chan e -> IO ()
supplyVtyEvents vty mkEvent chan =
    forever $ do
        e <- nextEvent vty
        writeChan chan $ mkEvent e

runVty :: Vty -> Chan e -> App a e -> a -> RenderState -> IO a
runVty vty chan app appState rs = do
    newRS <- renderApp vty app appState rs
    e <- readChan chan
    (next, scrollReqs) <- runStateT (appHandleEvent app e appState) []
    case next of
        Shutdown finalAppState -> return finalAppState
        Continue newAppState -> runVty vty chan app newAppState $ newRS { _scrollRequests = scrollReqs }

withVty :: IO Vty -> (Vty -> IO a) -> IO a
withVty buildVty useVty = do
    vty <- buildVty
    useVty vty `finally` shutdown vty

renderApp :: Vty -> App a e -> a -> RenderState -> IO RenderState
renderApp vty app appState rs = do
    sz <- displayBounds $ outputIface vty
    let (newRS, pic, theCursor) = renderFinal (appAttrMap app appState) (appDraw app appState) sz (appChooseCursor app appState) rs
        picWithCursor = case theCursor of
            Nothing -> pic { picCursor = NoCursor }
            Just (CursorLocation (Location (w, h)) _) -> pic { picCursor = Cursor w h }

    update vty picWithCursor

    return newRS

neverShowCursor :: a -> [CursorLocation] -> Maybe CursorLocation
neverShowCursor = const $ const Nothing

showFirstCursor :: a -> [CursorLocation] -> Maybe CursorLocation
showFirstCursor = const $ listToMaybe

data ViewportScroll =
    ViewportScroll { viewportName :: Name
                   , scrollPage :: Direction -> EventM ()
                   , scrollBy :: Int -> EventM ()
                   , scrollToBeginning :: EventM ()
                   , scrollToEnd :: EventM ()
                   }

viewportScroll :: Name -> ViewportScroll
viewportScroll n =
    ViewportScroll { viewportName = n
                   , scrollPage = \dir -> modify ((n, ScrollPage dir) :)
                   , scrollBy = \i -> modify ((n, ScrollBy i) :)
                   , scrollToBeginning = modify ((n, ScrollToBeginning) :)
                   , scrollToEnd = modify ((n, ScrollToEnd) :)
                   }
