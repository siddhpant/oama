{-# LANGUAGE ImportQualifiedPost   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module MailCtl.Authorization
  ( getEmailPwd
  , getEmailAuth
  , authorizeEmail
  , forceRenew
  )
where

import Control.Concurrent
import Control.Monad.IO.Class
import Control.Exception (try)
import Data.Aeson (encode, eitherDecode', eitherDecodeStrict)
import Data.Bifunctor (bimap)
import Data.ByteString.Lazy (fromStrict)
import Data.ByteString.Lazy.UTF8 qualified as BLU
import Data.ByteString.UTF8 qualified as BSU
import Data.Map qualified as M
import Data.Maybe (fromMaybe)
import Data.Time.Clock
import Data.Time.Format
import MailCtl.Environment
import MailCtl.Utilities (logger)
import Network.HTTP.Conduit
import Network.HTTP.Simple
import Network.Wai.Handler.Warp (run)
import System.Directory qualified as D
import System.Environment qualified as E
import System.Exit (ExitCode (ExitSuccess), exitWith, exitFailure)
import System.IO qualified as IO
import System.Posix.Syslog (Priority(..))
import System.Process qualified as P
import Text.Printf
import Web.Twain qualified as TW
-- import Text.Pretty.Simple

-- The OAuth2 authorization flow is implemented along the lines of
-- https://developers.google.com/identity/protocols/oauth2/native-app
-- The managed credentials are kept in encrypted files using GNU PG.

readAuthRecord :: Environment -> EmailAddress -> IO AuthRecord
readAuthRecord env email_ = do
  let gpgFile = oauth2_dir (config env) ++ "/" ++ unEmailAddress email_ ++ ".auth"
  authRecExist <- D.doesFileExist gpgFile
  if authRecExist
    then do
      (x, o, e) <- P.readProcessWithExitCode (exec $ decrypt_cmd $ config env)
                                             (args (decrypt_cmd $ config env) ++ [gpgFile]) ""
      if x == ExitSuccess
        then case eitherDecode' (BLU.fromString o) :: Either String AuthRecord of
                  Left err -> error $ "readAuthRecord:\n" ++ err
                  Right rec -> return rec
        else do
          putStr e
          exitWith x
    else do
      putStrLn $ "Can't find authorization record for " ++ unEmailAddress email_
      putStrLn "You must run the 'authorize' command before using other operations."
      exitFailure

writeAuthRecord :: Environment -> EmailAddress -> AuthRecord -> IO ()
writeAuthRecord env email_ rec = do
  let gpgFile = oauth2_dir (config env) ++ "/" ++ unEmailAddress email_ ++ ".auth"
      jsrec = BLU.toString $ encode rec
  (Just h, _, _, p) <- P.createProcess (P.proc (exec $ encrypt_cmd $ config env)
                         (args  (encrypt_cmd $ config env) ++ [gpgFile ++ ".new"]))
                         { P.std_in = P.CreatePipe }
  IO.hPutStr h jsrec 
  IO.hFlush h
  IO.hClose h
  x <- P.waitForProcess p
  if x == ExitSuccess
    then D.renameFile (gpgFile ++ ".new") gpgFile
    else exitWith x

timeStampFormat :: String
timeStampFormat = "%Y-%m-%d %H:%M %Z"

-- Provide access_token while renewing it when necessary

getEmailAuth :: Environment -> EmailAddress -> IO ()
getEmailAuth env email_ = do
  authrec <- getEmailAuth' env email_
  case authrec of
    Right rec -> putStrLn $ access_token rec
    Left errmsg -> error $ "getEmailAuth:\n" ++ errmsg

getEmailAuth' :: Environment -> EmailAddress -> IO (Either String AuthRecord)
getEmailAuth' env email_ = do
  authrec <- readAuthRecord env email_
  now <- getCurrentTime
  let expd = fromMaybe "2000-01-01 12:00 UTC" (exp_date authrec)
  if now > parseTimeOrError True defaultTimeLocale timeStampFormat expd
    then do
      newa <- renewAccessToken env (service authrec) (refresh_token authrec)
      case newa of
        Left err -> return $ Left err
        Right newA -> do
          let expire = addUTCTime (expires_in newA - 300) now
              expDate = formatTime defaultTimeLocale timeStampFormat expire
              authrec' = authrec { access_token = access_token newA
                         , expires_in = expires_in newA, exp_date = Just expDate
                         -- despite of google's doc refresh_token is not returned!
                         -- , refresh_token = refresh_token newA
                         , scope = scope newA
                         , token_type = token_type newA
                         }
          writeAuthRecord env email_ authrec'
          logger Notice $ printf "new acccess token for %s - expires at %s" (unEmailAddress email_) expDate
          return $ Right authrec'
        else return $ Right authrec

decodePostMode :: String -> PostMode
decodePostMode "request-body" = RequestBody
decodePostMode "query-string" = QueryString
decodePostMode "both"         = RequestBody
decodePostMode postmode       = error $ "Invalid PostMode: " <> postmode

postRequest :: PostMode -> String -> [(String, Maybe String)] -> IO (Either String BSU.ByteString)
postRequest postmode url params = do
  case postmode of
    RequestBody -> do
      -- send all parameters in request body
      req <- parseRequest $ "POST " ++ url
      let ps = [(x, y) | (x, Just y) <- params]
          mps = M.fromList ps
      runPost (setRequestBodyJSON mps req)
    QueryString -> do
      -- send all parameters as query strings
      let ps = [ bimap BSU.fromString (BSU.fromString <$>) x | x <- params ]
      req <- parseRequest $ "POST " ++ url
      runPost (setRequestQueryString ps req)
  where
    runPost query = do
      eresp <- try $ httpBS query :: IO (Either HttpException (Response BSU.ByteString))
      case eresp of
        Left (HttpExceptionRequest _ x) -> return $ Left $ show x
        Left (InvalidUrlException u _) -> return $ Left u
        Right resp -> return $ Right $ getResponseBody resp

fetchAuthRecord :: PostMode -> String -> [(String, Maybe String)] -> IO (Either String AuthRecord)
fetchAuthRecord postmode url queries = do
  eresp <- postRequest postmode url queries
  case eresp of
    Left err -> return $ Left err
    Right resp ->
      case eitherDecodeStrict resp :: Either String AuthRecord of
        Left err -> do
          putStrLn $ BSU.toString resp
          return $ Left $ "fetchAuthRecord: " ++ err
        Right rec -> return $ Right rec

renewAccessToken :: Environment -> Maybe String -> Maybe String -> IO (Either String AuthRecord)
renewAccessToken _ Nothing _ = return $ Left "renewAccessToken: Nothing as service string argument"
renewAccessToken _ _ Nothing = return $ Left "renewAccessToken: Nothing as refresh token argument"
renewAccessToken env (Just serv) (Just rft) = do
  let ss = services env
      qs = [ ("client_id", serviceFieldLookup ss serv client_id)
           , ("client_secret", serviceFieldLookup ss serv client_secret) 
           , ("grant_type", Just "refresh_token")
           , ("refresh_token", Just rft)
           ]
  case serviceFieldLookup ss serv token_endpoint of
    Nothing -> error "renewAccessToken: missing token_endpoint field in Services."
    Just tokenEndpoint ->
      case serviceFieldLookup ss serv token_postmode of
        Nothing -> error "renewAccessToken: missing token_postmode field in Services."
        Just postmode -> fetchAuthRecord (decodePostMode postmode) tokenEndpoint qs

forceRenew :: Environment -> EmailAddress -> IO ()
forceRenew env email_ = do
  authrec <- readAuthRecord env email_
  now <- getCurrentTime
  newa <- renewAccessToken env (service authrec) (refresh_token authrec)
  case newa of
    Left err -> error err
    Right newA -> do
      let expire = addUTCTime (expires_in newA - 300) now
          expDate = formatTime defaultTimeLocale timeStampFormat expire
          authrec' = authrec { access_token = access_token newA
                     , expires_in = expires_in newA, exp_date = Just expDate
                     -- despite of google's doc refresh_token is not returned!
                     -- , refresh_token = refresh_token newA
                     , scope = scope newA
                     , token_type = token_type newA
                     }
      writeAuthRecord env email_ authrec'
      logger Notice $ printf "new acccess token for %s - expires at %s" (unEmailAddress email_) expDate
      printf "Obtained new acccess token for %s - expires at %s.\n" (unEmailAddress email_) expDate


-- initial registration for authorization credentials

getAccessToken :: Environment -> Maybe String -> String -> IO (Either String AuthRecord)
getAccessToken _ Nothing _ = return $ Left "getAccessToken: missing service string"
getAccessToken env (Just serv) authcode = do
  let ss = services env
      qs = [ ("client_id", serviceFieldLookup ss serv client_id)
           , ("client_secret", serviceFieldLookup ss serv client_secret)
           , ("code", Just authcode)
           , ("grant_type", Just "authorization_code")
           , ("redirect_uri", serviceFieldLookup ss serv redirect_uri)
           ]
  case serviceFieldLookup ss serv token_endpoint of
    Nothing -> error "getAccessToken: missing token_endpoint field in Services."
    Just tokenEndpoint ->
      case serviceFieldLookup ss serv token_postmode of
        Nothing -> error "getAccessToken: missing token_postmode field in Services."
        Just postmode -> fetchAuthRecord (decodePostMode postmode) tokenEndpoint qs

generateAuthPage :: Environment -> Maybe String -> EmailAddress -> IO (Either String BSU.ByteString)
generateAuthPage _ Nothing _ = return $ Left "generateAuthPage: missing service string"
generateAuthPage env (Just serv) email_ = do
  let ss = services env
      qs = [ ("client_id", serviceFieldLookup ss serv client_id)
           , ("redirect_uri", serviceFieldLookup ss serv redirect_uri)
           , ("response_type", Just "code")
           , ("scope", serviceFieldLookup ss serv auth_scope)
           , ("login_hint", Just $ unEmailAddress email_)
           , ("tenant", serviceFieldLookup ss serv tenant)
           ]
  case serviceFieldLookup ss serv auth_endpoint of
    Nothing -> error "generateAuthPage: missing auth_endpoint field in Services."
    Just authEndpoint ->
      case serviceFieldLookup ss serv auth_postmode of
        Nothing -> error "generateAuthPage: missing auth_postmode field in Services."
        Just postmode -> postRequest (decodePostMode postmode) authEndpoint qs

localWebServer :: Environment -> Maybe String -> EmailAddress -> IO ()
localWebServer env serv email_ = do
  authPage <- generateAuthPage env serv email_
  case authPage of
    Left errmsg -> error $ "localWebServer:\n" ++ errmsg
    Right authP -> do
      let startAuth :: TW.ResponderM a
          startAuth = TW.send $ TW.html $ fromStrict authP
          finishAuth :: TW.ResponderM a
          finishAuth = do
            code :: String <- TW.param "code"
            authrec <- liftIO $ getAccessToken env serv code
            case authrec of
              Left errmsg -> do
                error $ "localWebServer:\n" ++ errmsg
              Right authr -> do
                now <- liftIO getCurrentTime
                let expire = addUTCTime (expires_in authr - 300) now
                    expDate = formatTime defaultTimeLocale timeStampFormat expire
                    authRec = authr { exp_date = Just expDate, email = Just email_, service = serv }
                liftIO $ writeAuthRecord env email_ authRec
                TW.send $ TW.html $ BLU.fromString $
                  printf "<h4>Received new refresh and access tokens for %s</h4>" (unEmailAddress email_)
                  <> printf "<p>They have been saved encrypted in <kbd>%s/%s.auth</kbd></p>"
                             (oauth2_dir (config env))  (unEmailAddress email_)
                  <> printf "<p>You may now quit the waiting <kbd>mailctl</kbd> program.</p>"
          routes :: [TW.Middleware]
          routes = [ TW.get "/start" startAuth
                   , TW.get "/" finishAuth
                   ]
          missing :: TW.ResponderM a
          missing = TW.send $ TW.html "Not found..."
      run 8080 $ foldr ($) (TW.notFound missing) routes

makeAuthRecord :: Environment -> String -> EmailAddress -> AuthRecord
makeAuthRecord env servName email_ =
  let services_ = services env
    in case M.lookup servName services_ of
        Nothing -> error $ "Can't find such service: " ++ servName
        Just serv ->
          AuthRecord "access_token_palce_holder"
                     1
                     (fromMaybe "unknown" (auth_scope serv))
                     "Bearer"
                     (Just "2000-01-01 12:00 UTC")
                     (Just "refresh_token_place_holder")
                     (Just email_)
                     (Just servName)

authorizeEmail :: Environment -> String -> EmailAddress -> IO ()
authorizeEmail env servName email_ = do
  authFileExists <- D.doesFileExist $ oauth2_dir (config env) ++ "/" ++ unEmailAddress email_ ++ ".auth"
  authrec <- if authFileExists
              then readAuthRecord env email_
              else return $ makeAuthRecord env servName email_
  case service authrec of
    Nothing -> error "authorizeEmail: missing service field in AuthRecord."
    Just serv -> do
      case serviceFieldLookup (services env) serv redirect_uri of
        Nothing -> error "authorizeEmail: missing redirect_uri field in AuthRecord."
        Just redirect -> do
          putStrLn $ "To grant OAuth2 access to " ++ unEmailAddress email_ ++ " visit the local URL below with your browser."
          putStrLn $ redirect ++ "/start"
      _ <- forkIO $ localWebServer env (Just serv) email_
      putStrLn "Authorization started ... "
      putStrLn "Hit <Enter> when it has been completed --> "
      _ <- getLine
      putStrLn "Now try to fetch some email!"


-- Utilities for traditional password based email services
-- using [pass](https://www.passwordstore.org/) 

getEmailPwd :: Environment -> EmailAddress -> IO ()
getEmailPwd env email_ = do
  password <- getEmailPwd' env email_
  putStrLn password

getEmailPwd' :: Environment -> EmailAddress -> IO String
getEmailPwd' env email_ = do
  psd <- E.lookupEnv "PASSWORD_STORE_DIR"
  case psd of
    Nothing -> do
      case password_store $ config env of
        Just password_store' -> do
          E.setEnv "PASSWORD_STORE_DIR" password_store'
          getEPwd
        Nothing -> do
          putStrLn "getEmailPwd': there is no 'password_store' configured nor PASSWORD_STORE_DIR environment variable set."
          exitFailure
    _ -> getEPwd
 where
  getEPwd = do
    case pass_cmd $ config env of
      Just pass_cmd' -> do
        (x, o, e) <- P.readProcessWithExitCode (exec pass_cmd')
                       [head (args pass_cmd') ++ unEmailAddress email_] []
        if x == ExitSuccess
          then return $ head (lines o)
          else do
            putStr e
            exitWith x
      Nothing -> do
        putStrLn "getEmailPwd': there is no 'pass_cmd' configured."
        exitFailure

