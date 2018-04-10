#define PERL_NO_GET_CONTEXT      /* we want efficiency */
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

/*
 * Duktape is an embeddable Javascript engine, with a focus on portability and
 * compact footprint.
 *
 * http://duktape.org/index.html
 */
#include "duktape.h"
#include "c_eventloop.h"

#define UNUSED_ARG(x) (void) x
#define DUK_SLOT_CALLBACK "_perl_.callback"

/*
 * We use these two functions to convert back and forth between the Perl
 * representation of an object and the JS one.
 *
 * Because data in Perl and JS can be nested (array of hashes of arrays of...),
 * the functions are recursive.
 *
 * duk_to_perl: takes a JS value from a given position in the duktape stack,
 * and creates the equivalent Perl value.
 *
 * perl_to_duk: takes a Perl value and leaves the equivalent JS value at the
 * top of the duktape stack.
 */
static SV* duk_to_perl(pTHX_ duk_context* ctx, int pos);
static int perl_to_duk(pTHX_ SV* value, duk_context* ctx);

/*
 * Native print callable from JS
 */
static duk_ret_t native_print(duk_context *ctx)
{
    duk_push_lstring(ctx, " ", 1);
    duk_insert(ctx, 0);
    duk_join(ctx, duk_get_top(ctx) - 1);
    PerlIO_stdoutf("%s\n", duk_safe_to_string(ctx, -1));
    return 0; // no return value
}

/*
 * Get JS compatible 'now' timestamp (millisecs since 1970).
 */
static duk_ret_t native_now(duk_context *ctx)
{
    struct timeval tv;
    double now = 0.0;
    int rc = gettimeofday(&tv, 0);
    if (rc == 0) {
        now = (((double) tv.tv_sec)  * 1000.0 +
               ((double) tv.tv_usec) / 1000.0);
    }
    duk_push_number(ctx, (duk_double_t) now);
    return 1; //  return value at top
}

/*
 * This is a generic dispatcher that allows calling any Perl function from JS,
 * after it has been registered under a name in JS.
 */
static duk_ret_t perl_caller(duk_context *ctx)
{
    duk_idx_t j = 0;

    // get actual Perl CV stored as a function property
    duk_push_current_function(ctx);
    if (!duk_get_prop_lstring(ctx, -1, DUK_SLOT_CALLBACK, sizeof(DUK_SLOT_CALLBACK) - 1)) {
        croak("Calling Perl handler for a non-Perl function\n");
    }
    SV* func = (SV*) duk_get_pointer(ctx, -1);
    duk_pop_2(ctx);  /* pop pointer and function */
    if (func == 0) {
        croak("Could not get value for property %s\n", DUK_SLOT_CALLBACK);
    }

    // prepare Perl environment for calling the CV
    dTHX;
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);

    // pass in the stack each of the params we received
    duk_idx_t nargs = duk_get_top(ctx);
    for (j = 0; j < nargs; j++) {
        SV* val = duk_to_perl(aTHX_ ctx, j);
        mXPUSHs(val);
    }

    // call actual Perl CV, passing all params
    PUTBACK;
    call_sv(func, G_SCALAR | G_EVAL);
    SPAGAIN;

    // get returned value from Perl and push its JS equivalent back in
    // duktape's stack
    SV* ret = POPs;
    perl_to_duk(aTHX_ ret, ctx);

    // cleanup and return 1, indicating we are returning a value
    PUTBACK;
    FREETMPS;
    LEAVE;
    return 1;
}

static SV* duk_to_perl(pTHX_ duk_context* ctx, int pos)
{
    SV* ret = &PL_sv_undef; // return undef by default
    switch (duk_get_type(ctx, pos)) {
        case DUK_TYPE_NONE:
        case DUK_TYPE_UNDEFINED:
        case DUK_TYPE_NULL: {
            break;
        }
        case DUK_TYPE_BOOLEAN: {
            duk_bool_t val = duk_get_boolean(ctx, pos);
            ret = newSViv(val);
            break;
        }
        case DUK_TYPE_NUMBER: {
            duk_double_t val = duk_get_number(ctx, pos);
            ret = newSVnv(val);  // JS numbers are always doubles
            break;
        }
        case DUK_TYPE_STRING: {
            duk_size_t clen = 0;
            const char* cstr = duk_get_lstring(ctx, pos, &clen);
            ret = newSVpvn(cstr, clen);
            break;
        }
        case DUK_TYPE_OBJECT: {
            if (duk_is_c_function(ctx, pos)) {
                // if the JS function has a slot with the Perl callback,
                // then we know we created it, so we return that
                if (!duk_get_prop_lstring(ctx, -1, DUK_SLOT_CALLBACK, sizeof(DUK_SLOT_CALLBACK) - 1)) {
                    croak("JS object is an unrecognized function\n");
                }
                ret = (SV*) duk_get_pointer(ctx, -1);
                duk_pop(ctx); // pop function
            } else if (duk_is_array(ctx, pos)) {
                int array_top = duk_get_length(ctx, pos);
                AV* values = newAV();
                int j = 0;
                for (j = 0; j < array_top; ++j) {
                    if (!duk_get_prop_index(ctx, pos, j)) {
                        continue; // index doesn't exist => end of array
                    }
                    SV* nested = sv_2mortal(duk_to_perl(aTHX_ ctx, -1));
                    duk_pop(ctx); // value in current pos
                    if (!nested) {
                        croak("Could not create Perl SV for array");
                    }
                    if (av_store(values, j, nested)) {
                        SvREFCNT_inc(nested);
                    }
                }
                ret = newRV_noinc((SV*) values);
            } else if (duk_is_object(ctx, pos)) {
                HV* values = newHV();
                duk_enum(ctx, pos, 0);
                while (duk_next(ctx, -1, 1)) { // get key and value
                    duk_size_t klen = 0;
                    const char* kstr = duk_get_lstring(ctx, -2, &klen);
                    SV* nested = sv_2mortal(duk_to_perl(aTHX_ ctx, -1));
                    duk_pop_2(ctx); // key and value
                    if (!nested) {
                        croak("Could not create Perl SV for hash");
                    }
                    if (hv_store(values, kstr, klen, nested, 0)) {
                        SvREFCNT_inc(nested);
                    }
                }
                duk_pop(ctx);  // iterator
                ret = newRV_noinc((SV*) values);
            } else {
                croak("JS object with an unrecognized type\n");
            }
            break;
        }
        case DUK_TYPE_POINTER: {
            ret = (SV*) duk_get_pointer(ctx, -1);
            break;
        }
        case DUK_TYPE_BUFFER: {
            croak("Don't know how to deal with a JS buffer\n");
            break;
        }
        case DUK_TYPE_LIGHTFUNC: {
            croak("Don't know how to deal with a JS lightfunc\n");
            break;
        }
        default:
            croak("Don't know how to deal with an undetermined JS object\n");
            break;
    }
    return ret;
}

static int perl_to_duk(pTHX_ SV* value, duk_context* ctx)
{
    int ret = 1;
    if (!SvOK(value)) {
        duk_push_null(ctx);
    } else if (SvIOK(value)) {
        int val = SvIV(value);
        duk_push_int(ctx, val);
    } else if (SvNOK(value)) {
        double val = SvNV(value);
        duk_push_number(ctx, val);
    } else if (SvPOK(value)) {
        STRLEN vlen = 0;
        const char* vstr = SvPV_const(value, vlen);
        duk_push_lstring(ctx, vstr, vlen);
    } else if (SvROK(value)) {
        SV* ref = SvRV(value);
        if (SvTYPE(ref) == SVt_PVAV) {
            AV* values = (AV*) ref;
            duk_idx_t array_pos = duk_push_array(ctx);
            int array_top = av_top_index(values);
            int count = 0;
            int j = 0;
            for (j = 0; j <= array_top; ++j) { // yes, [0, array_top]
                SV** elem = av_fetch(values, j, 0);
                if (!elem || !*elem) {
                    break; // could not get element
                }
                if (!perl_to_duk(aTHX_ *elem, ctx)) {
                    croak("Could not create JS element for array");
                }
                if (!duk_put_prop_index(ctx, array_pos, count)) {
                    croak("Could not push JS element for array");
                }
                ++count;
            }
        } else if (SvTYPE(ref) == SVt_PVHV) {
            HV* values = (HV*) ref;
            duk_idx_t hash_pos = duk_push_object(ctx);
            hv_iterinit(values);
            while (1) {
                SV* value = 0;
                I32 klen = 0;
                char* kstr = 0;
                HE* entry = hv_iternext(values);
                if (!entry) {
                    break; // no more hash keys
                }
                kstr = hv_iterkey(entry, &klen);
                if (!kstr || klen < 0) {
                    continue; // invalid key
                }
                value = hv_iterval(values, entry);
                if (!value) {
                    continue; // invalid value
                }
                if (!perl_to_duk(aTHX_ value, ctx)) {
                    croak("Could not create JS element for hash");
                }
                if (! duk_put_prop_lstring(ctx, hash_pos, kstr, klen)) {
                    croak("Could not push JS element for hash");
                }
            }
        } else if (SvTYPE(ref) == SVt_PVCV) {
            // use perl_caller as generic handler, but store the real callback
            // in a slot, from where we can later retrieve it
            duk_push_c_function(ctx, perl_caller, DUK_VARARGS);
            SV* func = newSVsv(value);
            if (!func) {
                croak("Could not create copy of Perl callback");
            }
            duk_push_pointer(ctx, func);
            if (! duk_put_prop_lstring(ctx, -2, DUK_SLOT_CALLBACK, sizeof(DUK_SLOT_CALLBACK) - 1)) {
                croak("Could not associate C dispatcher and Perl callback");
            }
        } else {
            croak("Don't know how to deal with an undetermined Perl reference\n");
            ret = 0;
        }
    } else {
        croak("Don't know how to deal with an undetermined Perl object\n");
        ret = 0;
    }
    return ret;
}

static int set_global_or_property(pTHX_ duk_context* ctx, const char* name, SV* value)
{
    if (sv_isobject(value)) {
        SV* obj = newSVsv(value);
        duk_push_pointer(ctx, obj);
    } else if (!perl_to_duk(aTHX_ value, ctx)) {
        return 0;
    }
    int last_dot = -1;
    int len = 0;
    for (; name[len] != '\0'; ++len) {
        if (name[len] == '.') {
            last_dot = len;
        }
    }
    if (last_dot < 0) {
        if (!duk_put_global_lstring(ctx, name, len)) {
            croak("Could not save duk value for %s\n", name);
        }
    } else {
        duk_push_lstring(ctx, name + last_dot + 1, len - last_dot - 1);
        if (duk_peval_lstring(ctx, name, last_dot) != 0) {
            croak("Could not eval JS object %*.*s: %s\n",
                  last_dot, last_dot,name,  duk_safe_to_string(ctx, -1));
        }
#if 0
        duk_enum(ctx, -1, 0);
        while (duk_next(ctx, -1, 0)) {
            fprintf(stderr, "KEY [%s]\n", duk_get_string(ctx, -1));
            duk_pop(ctx);  /* pop_key */
        }
#endif
         // Have [value, key, object], need [object, key, value], hence swap
        duk_swap(ctx, -3, -1);
        duk_put_prop(ctx, -3);
        duk_pop(ctx); // pop object
    }
    return 1;
}

static int session_dtor(pTHX_ SV* sv, MAGIC* mg)
{
    UNUSED_ARG(sv);
    duk_context* ctx = (duk_context*) mg->mg_ptr;
    duk_destroy_heap(ctx);
    return 0;
}

static void duk_fatal_error_handler(void* data, const char *msg)
{
    UNUSED_ARG(data);
    dTHX;
    PerlIO_printf(PerlIO_stderr(), "duktape fatal error, aborting: %s\n", msg ? msg : "*NONE*");
    abort();
}

static int register_native_functions(pTHX_ duk_context* ctx)
{
    static struct Data {
        const char* name;
        duk_c_function func;
    } data[] = {
        { "print"       , native_print },
        { "timestamp_ms", native_now   },
    };
    int n = sizeof(data) / sizeof(data[0]);
    int j = 0;
    for (j = 0; j < n; ++j) {
        duk_push_c_function(ctx, data[j].func, DUK_VARARGS);
        if (!duk_put_global_string(ctx, data[j].name)) {
            croak("Could not register native function %s\n", data[j].name);
        }
    }

    // Register our event loop dispatcher, otherwise calls to
    // dispatch_function_in_event_loop will not work.
    eventloop_register(ctx);

    return n;
}

static int run_function_in_event_loop(duk_context* ctx, const char* func)
{
    // Start a zero timer which will call our function from the event loop.
    int rc = 0;
    char js[256];
    int len = sprintf(js, "setTimeout(function() { %s(); }, 0);", func);
    rc = duk_peval_lstring(ctx, js, len);
    if (rc != 0) {
        croak("Could not eval JS event loop dispatcher %*.*s: %d - %s\n",
              len, len, js, rc, duk_safe_to_string(ctx, -1));
    }
    duk_pop(ctx);

    // Launch eventloop; this call only returns after the eventloop terminates.
    rc = duk_safe_call(ctx, eventloop_run, NULL, 0 /*nargs*/, 1 /*nrets*/);
    if (rc != 0) {
        croak("JS event loop run failed: %d - %s\n",
              rc, duk_safe_to_string(ctx, -1));
    }
    duk_pop(ctx);

    return 0;
}

static MGVTBL session_magic_vtbl = { .svt_free = session_dtor };

MODULE = JavaScript::Duktape::XS       PACKAGE = JavaScript::Duktape::XS
PROTOTYPES: DISABLE

#################################################################

duk_context*
new(char* CLASS, HV* opt = NULL)
  CODE:
    UNUSED_ARG(opt);
    RETVAL = duk_create_heap(0, 0, 0, (void*) 0xdeadbeef, duk_fatal_error_handler);
    if (!RETVAL) {
        croak("Could not create duk heap\n");
    }
    register_native_functions(aTHX_ RETVAL);
  OUTPUT: RETVAL

SV*
get(duk_context* ctx, const char* name)
  CODE:
    RETVAL = &PL_sv_undef; // return undef by default
    if (duk_get_global_string(ctx, name)) {
        RETVAL = duk_to_perl(aTHX_ ctx, -1);
        duk_pop(ctx);
    }
  OUTPUT: RETVAL

int
set(duk_context* ctx, const char* name, SV* value)
  CODE:
    RETVAL = set_global_or_property(aTHX_ ctx, name, value);
  OUTPUT: RETVAL

SV*
eval(duk_context* ctx, const char* js)
  CODE:
    duk_uint_t flags = 0;
    /* flags |= DUK_COMPILE_STRICT; */
    if (duk_pcompile_string(ctx, flags, js)) {
        croak("JS could not compile code: %s\n", duk_safe_to_string(ctx, -1));
    }
    duk_call(ctx, 0);
    RETVAL = duk_to_perl(aTHX_ ctx, -1);
    duk_pop(ctx);
  OUTPUT: RETVAL

SV*
dispatch_function_in_event_loop(duk_context* ctx, const char* func)
  CODE:
    RETVAL = newSViv(run_function_in_event_loop(ctx, func));
  OUTPUT: RETVAL
