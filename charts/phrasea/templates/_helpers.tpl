{{/*
Check if resourceQuota is enabled for a component.
Uses component-level value if defined, otherwise falls back to global value.
Usage: {{ include "ps.resourceQuota" (dict "local" .resourceQuota "global" $.Values.resourceQuota) }}
*/}}
{{- define "ps.resourceQuota" -}}
{{- if not (kindIs "invalid" .local) -}}
{{- .local -}}
{{- else -}}
{{- .global | default false -}}
{{- end -}}
{{- end -}}

{{- define "ps.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "ps" .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "ps.name" -}}
{{- .Values.nameOverride | default "ps" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "imagePullSecrets" }}
{{- if .Values.image.pullSecret.enabled }}
imagePullSecrets:
- name: {{ .Values.image.pullSecret.name }}
{{- end }}
{{- end }}

{{- define "secretName.rabbitmq" -}}
{{- .Values.rabbitmq.externalSecretName | default "rabbitmq-secret" -}}
{{- end }}
{{- define "secretName.postgresql" -}}
{{- .Values.postgresql.externalSecretName | default "postgresql-secret" -}}
{{- end }}
{{- define "secretName.mailer" -}}
{{- .Values.mailer.externalSecretName | default "mailer" -}}
{{- end }}

{{- define "secretRef.ingress.tls.wildcard" -}}
{{- with .Values.ingress.tls.wildcard }}
{{- if and .enabled .externalSecretName -}}
{{- .externalSecretName -}}
{{- else if $.Values.acme.enabled -}}
{{- printf "%s-wildcard-tls" (include "ps.fullname" $) -}}
{{- else -}}
gateway-tls
{{- end }}
{{- end }}
{{- end }}

{{/*
Soketi server side endpoint for PHP services (overrides the public SOKETI_HOST of the soketi/urls-config ConfigMaps).
*/}}
{{- define "envRef.soketi" }}
{{- if and .Values.soketi.enabled .Values.soketi.serverSide.internal }}
- name: SOKETI_HOST
  value: {{ .Values.soketi.serverSide.host | quote }}
- name: SOKETI_PORT
  value: {{ .Values.soketi.serverSide.port | quote }}
- name: SOKETI_SCHEME
  value: {{ .Values.soketi.serverSide.scheme | quote }}
{{- end }}
{{- end }}

{{- define "envFrom.rabbitmq" }}
- configMapRef:
    name: rabbitmq-php-config
- secretRef:
    name: {{ include "secretName.rabbitmq" . }}
{{- end }}

{{- define "envFrom.postgresql" }}
- configMapRef:
    name: postgresql-php-config
- secretRef:
    name: {{ include "secretName.postgresql" . }}
{{- end }}

{{- define "envFrom.phpApp.base" }}
- configMapRef:
    name: php-config
- configMapRef:
    name: urls-config
- configMapRef:
    name: configurator-s3
{{- end }}
{{- define "envFrom.phpApp" }}
{{- include "envFrom.phpApp.base" . }}
- configMapRef:
    name: mailer
- secretRef:
    name: {{ include "secretName.mailer" . }}
{{- end }}

{{/*
envFrom shared by the long running PHP services of an app (API, worker, cron jobs).
Usage: {{ include "envFrom.phpService" (dict "app" $appName "ctx" . "glob" $ "worker" true) }}
*/}}
{{- define "envFrom.phpService" }}
{{- $appName := .app }}
{{- $ctx := .ctx }}
{{- $glob := .glob }}
{{- if $ctx.adminOAuthClient }}
- secretRef:
    name: {{ $ctx.adminOAuthClient.externalSecretName | default (printf "%s-admin-oauth-client-secret" $appName) }}
{{- end }}
{{- if eq "databox" $appName }}
- secretRef:
    name: {{ $appName }}-secrets
{{- if .worker }}
- secretRef:
    name: {{ $appName }}-worker-secrets
{{- end }}
- configMapRef:
    name: imagemagick-policies
{{- end }}
- configMapRef:
    name: {{ $appName }}-api-config
{{- if $glob.Values.soketi.enabled }}
- configMapRef:
    name: soketi
- secretRef:
    name: soketi
{{- end }}
{{- if $glob.Values.matomo.enabled }}
- configMapRef:
    name: matomo
- secretRef:
    name: matomo
{{- end }}
{{- end }}

{{- define "envRef.phpApp" }}
{{- $appName := .app }}
{{- $ctx := .ctx }}
{{- $glob := .glob }}
{{- if $ctx.api }}
{{- if $ctx.api.config }}
{{- if $ctx.api.config.s3Storage }}
{{- $secretName := $ctx.api.config.s3Storage.externalSecretKey | default (printf "%s-s3-secret" $appName) }}
{{- $mapping := $ctx.api.config.s3Storage.externalSecretMapping }}
- name: S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $mapping.accessKey }}
- name: S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $mapping.secretKey }}
{{- end }}
{{- end }}
{{- end }}
{{- if $ctx.rabbitmq }}
- name: RABBITMQ_VHOST
  value: {{ $ctx.rabbitmq.vhost | quote }}
{{- end }}
- name: CONFIGURATOR_DB_NAME
  value: {{ $glob.Values.configurator.database.name | quote }}
{{- if $ctx.database }}
- name: DB_NAME
  value: {{ $ctx.database.name | quote }}
{{- end }}
{{- end }}

{{- define "app.s3Storage.configMap" }}
{{- $ctx := .ctx }}
{{- $glob := .glob }}
{{- $appName := .app }}
{{- $appConfig := index $glob.Values $appName }}
S3_ENDPOINT: {{ tpl $ctx.s3Storage.endpoint $glob | quote }}
S3_REGION: {{ required (printf "Missing %s.api.config.s3Storage.region" $appName) $ctx.s3Storage.region | quote }}
S3_USE_PATH_STYLE_ENDPOINT: {{ or $ctx.s3Storage.usePathStyleEndpoint $glob.Values.minio.enabled | quote }}
S3_BUCKET_NAME: {{ $ctx.s3Storage.bucketName | quote }}
S3_PATH_PREFIX: {{ $ctx.s3Storage.pathPrefix | quote }}
S3_MULTIPART_MIN_CHUNK_SIZE: {{ $appConfig.s3MultipartMinChunkSize | quote }}
S3_MULTIPART_MAX_CHUNK_SIZE: {{ $appConfig.s3MultipartMaxChunkSize | quote }}
S3_MULTIPART_MAX_PART_NUMBER: {{ $appConfig.s3MultipartMaxPartNumber | quote }}
S3_MAX_OBJECT_SIZE: {{ $appConfig.s3MaxObjectSize | quote }}
{{- end }}

{{- define "app.cloudFront.configMap" }}
{{- $appName := .app }}
{{- $ctx := .ctx }}
{{- $glob := .glob }}
{{- if $ctx.cloudFront.url }}
CLOUD_FRONT_URL: {{ tpl $ctx.cloudFront.url $glob | quote }}
CLOUD_FRONT_REGION: {{ required (printf "Missing %s.api.config.cloudFront.region" $appName) $ctx.cloudFront.region | quote }}
CLOUD_FRONT_PRIVATE_KEY: {{ $ctx.cloudFront.privateKey | quote }}
CLOUD_FRONT_KEY_PAIR_ID: {{ $ctx.cloudFront.keyPairId | quote }}
CLOUD_FRONT_TTL: {{ $ctx.cloudFront.ttl | quote }}
{{- end }}
{{- end }}

{{- define "app.client.configMap" }}
{{- $ctx := .ctx }}
{{- $glob := .glob }}
DEV_MODE: "0"
CLIENT_ID: {{ $ctx.client.oauthClient.id | quote }}
{{- if $glob.Values.keycloak.autoConnectIdP }}
AUTO_CONNECT_IDP: {{ $glob.Values.keycloak.autoConnectIdP | quote }}
{{- end }}
{{- $sentry := $glob.Values.sentry | default dict }}
{{- $sentryFrontend := get $sentry "frontend" | default dict }}
{{- $sentryFrontendEnabled := get $sentryFrontend "enabled" }}
{{- if eq $sentryFrontendEnabled nil }}
{{- $sentryFrontendEnabled = (get $sentry "enabled" | default false) }}
{{- end }}
{{- $sentryFrontendDsn := get $sentryFrontend "clientDsn" }}
{{- if eq $sentryFrontendDsn nil }}
{{- $sentryFrontendDsn = (get $sentry "clientDsn") }}
{{- end }}
{{- if $sentryFrontendEnabled }}
SENTRY_DSN: {{ required "Missing sentry frontend DSN (sentry.frontend.clientDsn or sentry.clientDsn)" $sentryFrontendDsn | quote }}
SENTRY_ENVIRONMENT: {{ required "Missing sentry environment (sentry.environment)" (get $sentry "environment") | quote }}
{{- end }}
{{- if $glob.Values.matomo.enabled }}
MATOMO_URL: {{ required "Missing matomo.baseUrl" $glob.Values.matomo.baseUrl | quote }}
MATOMO_SITE_ID: {{ required "Missing matomo.siteId" $glob.Values.matomo.siteId | quote }}
MATOMO_MEDIA_PLUGIN_ENABLED: {{ $glob.Values.matomo.mediaPluginEnabled | quote }}
{{- end }}
{{- if $ctx.client }}
{{- if $ctx.client.csp }}
ALLOWED_FRAME_ANCESTORS: {{ $ctx.client.csp.allowedFrameAncestors | quote }}
{{- end }}
{{- end }}
{{- end }}

{{- define "ingress.apiVersion" -}}
{{- if .Capabilities.APIVersions.Has "networking.k8s.io/v1/Ingress" -}}
networking.k8s.io/v1
{{- else -}}
networking.k8s.io/v1beta1
{{- end -}}
{{- end -}}

{{- define "ingress.rule_path" }}
{{- if ._.Capabilities.APIVersions.Has "networking.k8s.io/v1/Ingress" }}
- backend:
    service:
      name: {{ .name }}
      port:
        number: {{ .port }}
  path: /
  pathType: Prefix
{{- else }}
- backend:
    serviceName: {{ .name }}
    servicePort: {{ .port }}
  path: {{ .path | default "/" }}
{{- end }}
{{- end }}

{{- define "configurator.containerSpecs" -}}
name: configurator
image: {{ .Values.repository.baseUrl }}/ps-configurator:{{ .Values.repository.tag }}
imagePullPolicy: {{ .Values.repository.imagePullPolicy }}
terminationMessagePolicy: FallbackToLogsOnError
env:
- name: PHRASEA_DOMAIN
  value: {{ .Values.stack.domain | quote }}
- name: VERIFY_SSL
  value: {{ .Values.security.verifySsl | quote }}
- name: VERIFY_HOST
  value: {{ .Values.security.verifyHost | quote }}
- name: AUTH_DB_NAME
  value: {{ .Values.auth.database.name | quote }}
{{- range $key, $value := .Values.configurator.configure }}
- name: CONFIGURATOR_CONFIGURE_{{ upper $key }}
  value: {{ $value | quote }}
{{- end }}
- name: CONFIGURATOR_DB_NAME
  value: {{ .Values.configurator.database.name | quote }}
- name: CONFIGURATOR_SERVICE_WAIT_TIMEOUT
  value: {{ .Values.configurator.serviceWaitTimeout | quote }}
- name: KEYCLOAK_ADMIN_PASSWORD_IS_DEFINITIVE
  value: {{ .Values.keycloak.defaultAdmin.passwordIsDefinitive | quote }}
- name: KC_REALM_HTML_DISPLAY_NAME
  value: {{ .Values.keycloak.realm.htmlDisplayName | quote }}
- name: KC_REALM_SUPPORTED_LOCALES
  value: {{ .Values.keycloak.realm.supportedLocales | quote }}
- name: KC_REALM_DEFAULT_LOCALE
  value: {{ .Values.keycloak.realm.defaultLocale | quote }}
- name: KC_REALM_LOGIN_REGISTRATION_ALLOWED
  value: {{ .Values.keycloak.realm.loginRegistrationAllowed | quote}}
- name: KC_REALM_LOGIN_RESET_PASSWORD_ALLOWED
  value: {{ .Values.keycloak.realm.loginResetPasswordAllowed | quote }}
- name: KC_REALM_LOGIN_REMEMBER_ME_ALLOWED
  value: {{ .Values.keycloak.realm.loginRememberMeAllowed | quote }}
- name: KC_REALM_LOGIN_WITH_EMAIL_ALLOWED
  value: {{ .Values.keycloak.realm.loginWithEmailAllowed | quote}}
- name: KC_REALM_LOGIN_VERIFY_EMAIL_ALLOWED
  value: {{ .Values.keycloak.realm.loginVerifyEmailAllowed | quote}}
- name: KC_REALM_LOGIN_EMAIL_AS_USERNAME
  value: {{ .Values.keycloak.realm.loginEmailAsUsername | quote }}
- name: KC_REALM_LOGIN_EDIT_USERNAME
  value: {{ .Values.keycloak.realm.loginEditUsername | quote }}
- name: KC_REALM_SSO_SESSION_IDLE_TIMEOUT
  value: {{ .Values.keycloak.realm.ssoSessionIdleTimeout | toString | quote }}
- name: KC_REALM_SSO_SESSION_MAX_LIFESPAN
  value: {{ .Values.keycloak.realm.ssoSessionMaxLifespan | toString | quote }}
- name: KC_REALM_CLIENT_SESSION_IDLE_TIMEOUT
  value: {{ .Values.keycloak.realm.clientSessionIdleTimeout | toString | quote }}
- name: KC_REALM_CLIENT_SESSION_MAX_LIFESPAN
  value: {{ .Values.keycloak.realm.clientSessionMaxLifespan | toString | quote }}
- name: KC_REALM_OFFLINE_SESSION_IDLE_TIMEOUT
  value: {{ .Values.keycloak.realm.offlineSessionIdleTimeout | toString | quote }}
- name: KC_REALM_OFFLINE_SESSION_MAX_LIFESPAN
  value: {{ .Values.keycloak.realm.offlineSessionMaxLifespan | toString | quote }}
- name: KC_REALM_USER_EVENT_ENABLED
  value: {{ .Values.keycloak.realm.userEventEnabled | quote }}
- name: KC_REALM_USER_EVENT_EXPIRATION
  value: {{ .Values.keycloak.realm.userEventExpiration | toString | quote }}
- name: KC_REALM_ADMIN_EVENT_ENABLED
  value: {{ .Values.keycloak.realm.adminEventEnabled | quote }}
- name: KC_REALM_ADMIN_EVENT_EXPIRATION
  value: {{ .Values.keycloak.realm.adminEventExpiration | toString | quote }}
- name: RABBITMQ_CONSOLE_URL
  value: {{ .Values.rabbitmq.consoleUrl | quote }}
- name: CONFIGURATOR_S3_BUCKET_NAME
  value: {{ .Values.configurator.s3.bucketName | quote }}
- name: S3_ENDPOINT
  value: {{ tpl .Values.configurator.s3.endpoint . | quote }}
{{- if .Values.minio.enabled }}
- name: S3_INTERNAL_URL
  value: {{ .Values.minio.internalBaseUrl | required "Missing minio.internalBaseUrl" | quote }}
{{- end }}
- name: S3_USE_PATH_STYLE_ENDPOINT
  value: {{ .Values.configurator.s3.usePathStyleEndpoint | quote }}
{{- $s3SecretName := .Values.configurator.s3.externalSecretKey | default "configurator-s3" }}
- name: S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $s3SecretName }}
      key: {{ .Values.configurator.s3.externalSecretMapping.accessKey }}
- name: S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $s3SecretName }}
      key: {{ .Values.configurator.s3.externalSecretMapping.secretKey }}
- name: S3_REGION
  value: {{ required "Missing configurator.s3.region" .Values.configurator.s3.region | quote }}
- name: S3_PATH_PREFIX
  value: {{ .Values.configurator.s3.pathPrefix | default "" | quote }}
- name: REPORT_DB_NAME
  value: {{ .Values.report.databaseName | required "Missing report.databaseName" | quote }}
- name: KEYCLOAK_DB_NAME
  value: {{ .Values.keycloak.database.name | required "Missing keycloak.database.name" | quote }}
{{- range .Values._internal.services }}
{{- $appName := . }}
{{- with (index $.Values $appName) }}
- name: {{ upper $appName }}_DB_NAME
  value: {{ .database.name | quote }}
- name: {{ upper $appName }}_RABBITMQ_VHOST
  value: {{ .rabbitmq.vhost | quote }}
- name: {{ upper $appName }}_S3_BUCKET_NAME
  value: {{ .api.config.s3Storage.bucketName | quote }}
{{- if .adminOAuthClient }}
{{- $oauthSecretName := .adminOAuthClient.externalSecretName | default (printf "%s-admin-oauth-client-secret" $appName) }}
- name: {{ upper $appName }}_ADMIN_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ $oauthSecretName }}
      key: ADMIN_CLIENT_ID
- name: {{ upper $appName }}_ADMIN_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ $oauthSecretName }}
      key: ADMIN_CLIENT_SECRET
{{- end }}
{{- end }}
{{- end }}
{{- with .Values.databox.exposeIntegration.clientId }}
- name: DATABOX_EXPOSE_INTEGRATION_CLIENT_ID
  value: {{ . | quote }}
{{- end }}
{{- with .Values.keycloak.defaultAdmin.email }}
- name: DEFAULT_ADMIN_EMAIL
  value: {{ . | quote }}
{{- end }}
{{- with .Values.databox.indexer.bucketName }}
- name: INDEXER_BUCKET_NAME
  value: {{ . | quote }}
{{- end }}
{{- with .Values.minio.notifyAmqpArn }}
- name: MINIO_NOTIFY_AMQP_ARN
  value: {{ . | quote }}
{{- end }}
{{- if .Values.databox.indexer.clientId }}
- name: INDEXER_DATABOX_CLIENT_ID
  value: {{ .Values.databox.indexer.clientId | quote }}
{{- end }}
{{- if .Values.databox.indexer.clientSecret }}
- name: INDEXER_DATABOX_CLIENT_SECRET
  value: {{ .Values.databox.indexer.clientSecret | quote }}
{{- end }}
{{- range .Values._internal.clients }}
{{- $appName := . }}
{{- with (index $.Values $appName) }}
- name: {{ upper $appName }}_CLIENT_ID
  value: {{ .client.oauthClient.id | quote }}
{{- end }}
{{- end }}
envFrom:
- secretRef:
    name: keycloak
{{- include "envFrom.phpApp" $ }}
{{- include "envFrom.rabbitmq" $ }}
{{- include "envFrom.postgresql" $ }}
{{- end }}

{{- define "envRef.configuratorSecrets" }}
{{- $secretName := .Values.configurator.s3.externalSecretKey | default "configurator-s3" }}
{{- $mapping := .Values.configurator.s3.externalSecretMapping }}
- name: CONFIGURATOR_S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $mapping.accessKey }}
- name: CONFIGURATOR_S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $mapping.secretKey }}
{{- end }}
