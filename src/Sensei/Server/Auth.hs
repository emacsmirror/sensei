{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Sensei.Server.Auth (
    AuthenticationToken (..),
    RegistrationToken (..),
    Credentials (..),
    UserRegistration (..),
    SerializedToken (..),
    Login,
    TokenID (..),
    Bytes (..),
    makeNewKey,
    readOrMakeKey,
    createKeys,
    createToken,
    makeToken,
    getKey,
    getPublicKey,
    setPassword,
    encrypt,
    authenticateUser,
    module Crypto.JOSE.JWK,
    decodeCompact,
    Error (..),
    SignedJWT,
    module SAS,
) where

import Control.Lens ((^.))
import Control.Monad (unless)
import Crypto.JOSE.Compact (decodeCompact)
import Crypto.JOSE.Error (Error (..))
import Crypto.JOSE.JWK
import Crypto.JWT (SignedJWT)
import Crypto.KDF.BCrypt
import Data.Aeson
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Proxy
import Data.String (IsString (..))
import Data.Text (Text, pack)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import GHC.Generics
import GHC.TypeLits (KnownNat, Nat, natVal)
import Preface.Codec
import Sensei.User (UserProfile (..))
import Servant
import Servant.Auth.Server as SAS
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.Random (newStdGen, randoms)

-- Tokens structure from AWS
-- AWS ID Token structure
-- {
-- "sub": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
-- "aud": "xxxxxxxxxxxxexample",
-- "email_verified": true,
-- "token_use": "id",
-- "auth_time": 1500009400,
-- "iss": "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_example",
-- "cognito:username": "janedoe",
-- "exp": 1500013000,
-- "given_name": "Jane",
-- "iat": 1500009400,
-- "email": "janedoe@example.com"
-- }

-- AWS Access Token payload

-- {
--     "auth_time": 1500009400,
--     "exp": 1500013000,
--     "iat": 1500009400,
--     "iss": "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_example",
--     "scope": "aws.cognito.signin.user.admin",
--     "sub": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
--     "token_use": "access",
--     "username": "janedoe@example.com"
-- }

-- https://www.iana.org/assignments/jwt/jwt.xhtml#claims
-- list of registered claims
-- iss	Issuer	[IESG]	[RFC7519, Section 4.1.1]
-- sub	Subject	[IESG]	[RFC7519, Section 4.1.2]
-- aud	Audience	[IESG]	[RFC7519, Section 4.1.3]
-- exp	Expiration Time	[IESG]	[RFC7519, Section 4.1.4]
-- nbf	Not Before	[IESG]	[RFC7519, Section 4.1.5]
-- iat	Issued At	[IESG]	[RFC7519, Section 4.1.6]
-- jti JWT ID

newtype Bytes (size :: Nat) = Bytes {unBytes :: Encoded Hex}
    deriving (Eq, Show, ToJSON, FromJSON)

instance KnownNat size => IsString (Bytes size) where
    fromString s =
        let e@(Encoded bs) = fromString s
            len = natVal (Proxy @size)
         in if BS.length bs == fromInteger len
                then Bytes e
                else error $ "bytestring should be of length " <> show len <> " but it was " <> show (BS.length bs)

-- | A token ID
newtype TokenID = TokenID {unTokenID :: Bytes 16}
    deriving (Eq, Show, ToJSON, FromJSON, IsString)

-- | A token issued for authenticated users
data AuthenticationToken = AuthToken
    { auID :: Encoded Hex
    , auOrgID :: Int
    }
    deriving (Eq, Show, Generic)

instance ToJSON AuthenticationToken

instance FromJSON AuthenticationToken

instance ToJWT AuthenticationToken

instance FromJWT AuthenticationToken

-- | A token issued to allow users to register
data RegistrationToken = RegToken
    { -- | The ID of the user who generated this token
      regID :: Int
    , tokID :: TokenID
    }
    deriving (Eq, Show, Generic)

instance ToJSON RegistrationToken

instance FromJSON RegistrationToken

instance ToJWT RegistrationToken

instance FromJWT RegistrationToken

type Login = ByteString

data Credentials = Credentials
    { credLogin :: Text
    , credPassword :: Text
    }
    deriving (Eq, Show, Generic)

instance ToJSON Credentials

instance FromJSON Credentials

data UserRegistration = UserRegistration
    { regLogin :: Text
    , regPassword :: Text
    , regToken :: SerializedToken
    }
    deriving (Eq, Show, Generic)

instance ToJSON UserRegistration where
    toJSON UserRegistration{..} =
        object
            [ "login" .= regLogin
            , "password" .= regPassword
            , "token" .= regToken
            ]

instance FromJSON UserRegistration where
    parseJSON = withObject "UserRegistration" $ \obj ->
        UserRegistration <$> obj .: "login" <*> obj .: "password" <*> obj .: "token"

-- | Generate a new random 4096-bits long RSA key pair.
makeNewKey :: IO JWK
makeNewKey = genJWK (RSAGenParam (4096 `div` 8))

{- | Read a key or create a new one.
 May throw an 'error' if the input contains a string that's not a valid 'JWK'
-}
readOrMakeKey :: Maybe String -> IO JWK
readOrMakeKey Nothing = makeNewKey
readOrMakeKey (Just keyString) =
    case eitherDecode (LBS.fromStrict $ encodeUtf8 $ pack keyString) of
        Left err -> error err
        Right k -> pure k

getKey :: FilePath -> IO JWK
getKey jwkFile = do
    exists <- doesFileExist jwkFile
    unless exists $ ioError $ userError $ "JWK file " <> jwkFile <> " does not exist"

    bytes <- BS.readFile jwkFile
    either (\err -> ioError $ userError ("Invalid JWK in file '" <> jwkFile <> "': " <> show err)) pure (eitherDecode $ LBS.fromStrict bytes)

createKeys :: FilePath -> IO ()
createKeys directory = makeNewKey >>= \jwk -> BS.writeFile (directory </> "sensei.jwk") (LBS.toStrict $ encode jwk)

createToken :: FilePath -> IO SerializedToken
createToken directory = do
    key <- getKey (directory </> "sensei.jwk")
    makeToken (defaultJWTSettings key) (AuthToken "" 1)

makeToken :: JWTSettings -> AuthenticationToken -> IO SerializedToken
makeToken settings authId =
    makeJWT authId settings Nothing >>= \case
        Left err -> error $ "Failed to create token :" <> show err
        Right jwt -> pure $ SerializedToken $ LBS.toStrict jwt

getPublicKey :: FilePath -> IO JWK
getPublicKey directory = do
    key <- getKey (directory </> "sensei.jwk")
    maybe (error $ "Fail to get public key from private key in " <> directory) pure $ key ^. asPublicKey

encrypt :: ByteString -> ByteString -> ByteString
encrypt = bcrypt cost

cost :: Int
cost = 10

setPassword :: UserProfile -> Text -> IO UserProfile
setPassword oldProfile newPassword = do
    g <- newStdGen
    let s = BS.pack $ take 16 $ randoms g
    pure $ oldProfile{userPassword = (toBase64 s, toBase64 $ encrypt s $ encodeUtf8 newPassword)}

authenticateUser :: Text -> UserProfile -> AuthResult AuthenticationToken
authenticateUser password UserProfile{userId, userPassword = (userSalt, hashedPassword)}
    | encrypt (fromBase64 userSalt) (encodeUtf8 password) == fromBase64 hashedPassword =
        SAS.Authenticated $ AuthToken userId 1
    | otherwise = SAS.BadPassword

newtype SerializedToken = SerializedToken {unToken :: ByteString}
    deriving (Eq, Show)

instance ToJSON SerializedToken where
    toJSON (SerializedToken bs) = String $ decodeUtf8 bs

instance FromJSON SerializedToken where
    parseJSON = withText "SerializedToken" $ \txt -> pure $ SerializedToken $ encodeUtf8 txt

instance MimeRender OctetStream SerializedToken where
    mimeRender _ (SerializedToken bs) = LBS.fromStrict bs
