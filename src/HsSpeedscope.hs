{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
module HsSpeedscope where


import Data.Aeson
import GHC.RTS.Events

import Data.Word
import Data.Text (Text)
import qualified Data.Vector.Unboxed as V
import System.Environment
import Data.Maybe
import Data.List.Extra
import Control.Monad
import Data.Char

import Data.Version
import Text.ParserCombinators.ReadP
import qualified Paths_hs_speedscope as Paths
import Debug.Trace

entry :: IO ()
entry = do
  fps <- getArgs
  case fps of
    [fp] -> do
      el <- either error id <$> readEventLogFromFile fp
      let (EventLog _ (Data es)) = el

      encodeFile (fp ++ ".json") (convertToSpeedscope el)
    _ -> error "Usage: hs-speedscope program.eventlog"

convertToSpeedscope :: EventLog -> Value
convertToSpeedscope (EventLog _h (Data (sortOn evTime -> es))) =
  case el_version of
    Just (ghc_version, _) | ghc_version < makeVersion [8,9,0]  ->
      error ("Eventlog is from ghc-" ++ showVersion ghc_version ++ " hs-speedscope only works with GHC 8.10 or later")
    _ -> object [ "version" .= ("0.0.1" :: String)
                , "$schema" .= ("https://www.speedscope.app/file-format-schema.json" :: String)
                , "shared" .= object [ "frames" .= ccs_json ]
                , "profiles" .= map (mkProfile profile_name interval) caps
                , "name" .= profile_name
                , "activeProfileIndex" .= (0 :: Int)
                , "exporter" .= version_string
                ]
  where
    (EL (fromMaybe "" -> profile_name) el_version (fromMaybe 1 -> interval) frames samples) =
      snd $ foldl' (flip processEvents) (False, initEL) es

    initEL = EL Nothing Nothing Nothing [] []


    version_string :: String
    version_string = "hs-speedscope@" ++ showVersion Paths.version

    -- Drop 7 events for built in cost centres like GC, IDLE etc
    ccs_raw = reverse (drop 7 (reverse frames))


    ccs_json :: [Value]
    ccs_json = map mkFrame ccs_raw

    num_frames = length ccs_json


    caps :: [(Capset, [[Int]])]
    caps = groupSort $ mapMaybe mkSample (reverse samples)

    mkFrame :: CostCentre -> Value
    mkFrame (CostCentre _n l _m s) = object [ "name" .= l, "file" .= s ]

    mkSample :: Sample -> Maybe (Capset, [Int])
    -- Filter out system frames
    mkSample (Sample _ti [k]) | fromIntegral k >= num_frames = Nothing
    mkSample (Sample ti ccs) = Just (ti, map (subtract 1 . fromIntegral) (reverse ccs))


    processEvents :: Event -> (Bool, EL) -> (Bool, EL)
    processEvents (Event _t ei _c) (do_sample, el) =
      case ei of
        ProgramArgs _ (pname: _args) ->
          (do_sample, el { prog_name = Just pname })
        RtsIdentifier _ rts_ident ->
          (do_sample, el { rts_version = parseIdent rts_ident })
        ProfBegin ival ->
          (do_sample, el { prof_interval = Just ival })
        HeapProfCostCentre n l m s _ ->
          (do_sample, el { cost_centres = CostCentre n l m s : cost_centres el })
        ProfSampleCostCentre t _ _ st ->
          if do_sample then
            (do_sample, el { el_samples = Sample t (V.toList st) : el_samples el })
            else (do_sample, el)
        (UserMarker "start") -> (True, el)
        (UserMarker "end") -> (False, el)
        _ -> (do_sample, el)

mkProfile :: String -> Word64 -> (Capset, [[Int]]) -> Value
mkProfile pname interval (_n, samples) =
  object [ "type" .= ("sampled" :: String)
         , "unit" .= ("nanoseconds" :: String)
         , "name" .= pname
         , "startValue" .= (0 :: Int)
         , "endValue" .= (length samples :: Int)
         , "samples" .= samples
         , "weights" .= sample_weights ]
  where
    sample_weights :: [Word64]
    sample_weights = replicate (length samples) interval

parseIdent :: String -> Maybe (Version, String)
parseIdent s = listToMaybe $ flip readP_to_S s $ do
  void $ string "GHC-"
  [v1, v2, v3] <- replicateM 3 (intP <* optional (char '.'))
  skipSpaces
  return (makeVersion [v1,v2,v3])
  where
    intP = do
      x <- munch1 isDigit
      return $ read x

data EL = EL {
    prog_name :: Maybe String
    , rts_version :: Maybe (Version, String)
    , prof_interval :: Maybe Word64
    , cost_centres :: [CostCentre]
    , el_samples :: [Sample]
}

data CostCentre = CostCentre Word32 Text Text Text deriving Show

data Sample = Sample Capset [Word32]
