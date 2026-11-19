/// Crypt32 and NCrypt declarations that druntime's core.sys.windows.wincrypt
/// lacks (it predates chain engines with exclusive roots and CNG). Windows
/// only; prototypes only, no code.
module camunda.wincrypt;

version (Windows):

@safe:

import core.sys.windows.windef : BOOL, BYTE, DWORD;
import core.sys.windows.wincrypt : CRYPT_DATA_BLOB, HCERTCHAINENGINE, HCERTSTORE, PCCERT_CONTEXT;

// Linked through "libs-windows" in dub.json (crypt32, ncrypt): a
// pragma(lib) here would sit in an object nothing pulls from the library.

/// CERT_CHAIN_ENGINE_CONFIG (Windows 8+ layout, with the exclusive root).
struct CertChainEngineConfig
{
    DWORD cbSize;
    HCERTSTORE hRestrictedRoot;
    HCERTSTORE hRestrictedTrust;
    HCERTSTORE hRestrictedOther;
    DWORD cAdditionalStore;
    HCERTSTORE* rghAdditionalStore;
    DWORD dwFlags;
    DWORD dwUrlRetrievalTimeout;
    DWORD MaximumCachedCertificates;
    DWORD CycleDetectionModulus;
    HCERTSTORE hExclusiveRoot;
    HCERTSTORE hExclusiveTrustedPeople;
    DWORD dwExclusiveFlags;
}

/// CRYPT_KEY_PROV_INFO.
struct CryptKeyProvInfo
{
    const(wchar)* pwszContainerName;
    const(wchar)* pwszProvName;
    DWORD dwProvType;
    DWORD dwFlags;
    DWORD cProvParam;
    void* rgProvParam;
    DWORD dwKeySpec;
}

/// NCryptBuffer / NCryptBufferDesc.
struct NCryptBuffer
{
    uint cbBuffer;
    uint BufferType;
    const(void)* pvBuffer;
}

/// ditto
struct NCryptBufferDesc
{
    uint ulVersion;
    uint cBuffers;
    NCryptBuffer* pBuffers;
}

alias NCRYPT_HANDLE = size_t;

enum : DWORD
{
    CERT_STORE_ADD_REPLACE_EXISTING = 3,
    CERT_KEY_PROV_INFO_PROP_ID = 2,
    CERT_CHAIN_EXCLUSIVE_ENABLE_CA_FLAG = 0x1,
    CERT_CHAIN_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT = 0x40000000,
    CERT_CHAIN_REVOCATION_ACCUMULATIVE_TIMEOUT = 0x08000000,
    CERT_CHAIN_POLICY_IGNORE_ALL_REV_UNKNOWN_FLAGS = 0x00000F00,
    NCRYPTBUFFER_PKCS_KEY_NAME = 45,
    NCRYPTBUFFER_PKCS_SECRET = 46,
    NCRYPT_OVERWRITE_KEY_FLAG = 0x80,
    NCRYPT_DO_NOT_FINALIZE_FLAG = 0x400,
    CRYPT_USER_KEYSET = 0x1000,
    PKCS12_ALWAYS_CNG_KSP = 0x200,
}

/// The per-user CNG software key storage provider.
enum MS_KEY_STORAGE_PROVIDER = "Microsoft Software Key Storage Provider"w;

extern (Windows) @system nothrow @nogc
{
    PCCERT_CONTEXT CertCreateCertificateContext(DWORD dwCertEncodingType, const(BYTE)* pbCertEncoded, DWORD cbCertEncoded);
    BOOL CertAddCertificateContextToStore(HCERTSTORE hCertStore, PCCERT_CONTEXT pCertContext, DWORD dwAddDisposition, PCCERT_CONTEXT* ppStoreContext);
    BOOL CertSetCertificateContextProperty(PCCERT_CONTEXT pCertContext, DWORD dwPropId, DWORD dwFlags, const(void)* pvData);
    BOOL CertCreateCertificateChainEngine(CertChainEngineConfig* pConfig, HCERTCHAINENGINE* phChainEngine);
    void CertFreeCertificateChainEngine(HCERTCHAINENGINE hChainEngine);
    HCERTSTORE PFXImportCertStore(CRYPT_DATA_BLOB* pPFX, const(wchar)* szPassword, DWORD dwFlags);
    PCCERT_CONTEXT CertEnumCertificatesInStore(HCERTSTORE hCertStore, PCCERT_CONTEXT pPrevCertContext);
    BOOL CertGetCertificateContextProperty(PCCERT_CONTEXT pCertContext, DWORD dwPropId, void* pvData, DWORD* pcbData);
    PCCERT_CONTEXT CertDuplicateCertificateContext(PCCERT_CONTEXT pCertContext);

    int NCryptOpenStorageProvider(NCRYPT_HANDLE* phProvider, const(wchar)* pszProviderName, DWORD dwFlags);
    int NCryptImportKey(NCRYPT_HANDLE hProvider, NCRYPT_HANDLE hImportKey, const(wchar)* pszBlobType, NCryptBufferDesc* pParameterList, NCRYPT_HANDLE* phKey, const(BYTE)* pbData, DWORD cbData, DWORD dwFlags);
    int NCryptFinalizeKey(NCRYPT_HANDLE hKey, DWORD dwFlags);
    int NCryptOpenKey(NCRYPT_HANDLE hProvider, NCRYPT_HANDLE* phKey, const(wchar)* pszKeyName, DWORD dwLegacyKeySpec, DWORD dwFlags);
    int NCryptDeleteKey(NCRYPT_HANDLE hKey, DWORD dwFlags);
    int NCryptFreeObject(NCRYPT_HANDLE hObject);
}
