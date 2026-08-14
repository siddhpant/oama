module Main where

import OAMa.Authorization
import OAMa.CommandLine
import OAMa.Environment
import System.Posix.Internals (c_umask)
import System.Posix.Syslog (Facility (Mail), withSyslog)

main :: IO ()
main = do
  _ <- c_umask 0o77
  withSyslog "oama" [] Mail $ do
    env <- loadEnvironment
    case optCommand $ options env of
      Oauth2 serv emailAddress -> getEmailAuth env (EmailAddress emailAddress) serv
      ShowCreds serv emailAddress -> showCreds env (EmailAddress emailAddress) serv
      Renew serv emailAddress -> forceRenew env (EmailAddress emailAddress) serv
      Authorize servName emailAddress nohint device -> authorizeEmail env servName (EmailAddress emailAddress) nohint device
      PrintEnv -> pprintEnv env
      PrintTemplate -> printTemplate
