/* eslint-disable */
// Generated from x-profile-candidates-v1.schema.json. Do not edit by hand.
import * as __ajvFormats from "ajv-formats/dist/formats.js";
"use strict";
export const validate = validate20;
export default validate20;
const schema31 = {"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://syc.local/linkdigest/x-profile-candidates-v1.schema.json","title":"LinkDigest X Profile Candidates V1","description":"Language-neutral Native Messaging contract for in-memory X homepage work candidates. The request never saves, summarizes, or copies cookies. The ACK only means the App received candidates for a selection sheet; it does not mean a window is visible.","oneOf":[{"$ref":"#/$defs/XProfileCandidatesRequest"},{"$ref":"#/$defs/XProfileCandidatesPresented"}],"$defs":{"handle":{"type":"string","pattern":"^[A-Za-z0-9_]{1,15}$","not":{"enum":["home","explore","search","i","settings","login","logout","intent","signup","notifications","messages","compose","tos","privacy"]}},"tweetID":{"type":"string","pattern":"^[0-9]{8,25}$"},"httpsXProfileURL":{"type":"string","maxLength":128,"pattern":"^https://(www\\.)?(x\\.com|twitter\\.com)/[A-Za-z0-9_]{1,15}$"},"httpsXStatusURL":{"type":"string","maxLength":256,"pattern":"^https://(www\\.)?(x\\.com|twitter\\.com)/[A-Za-z0-9_]{1,15}/status/[0-9]{8,25}$"},"httpsTwimgProfileImageURL":{"type":"string","minLength":40,"maxLength":2048,"pattern":"^https://([A-Za-z0-9-]+\\.)?twimg\\.com/profile_images/"},"XProfileCandidateItem":{"type":"object","additionalProperties":false,"required":["id","url"],"properties":{"id":{"$ref":"#/$defs/tweetID"},"url":{"$ref":"#/$defs/httpsXStatusURL"},"previewText":{"type":"string","maxLength":200},"publishedText":{"type":"string","maxLength":40}}},"XProfileCandidatesRequest":{"type":"object","additionalProperties":false,"required":["kind","version","requestId","profileURL","authorID","items"],"properties":{"kind":{"const":"xProfileCandidates"},"version":{"type":"integer","const":1},"requestId":{"type":"string","minLength":1,"maxLength":128},"profileURL":{"$ref":"#/$defs/httpsXProfileURL"},"authorID":{"$ref":"#/$defs/handle"},"profileName":{"type":"string","maxLength":80},"profileAvatarURL":{"$ref":"#/$defs/httpsTwimgProfileImageURL"},"items":{"type":"array","minItems":1,"maxItems":100,"items":{"$ref":"#/$defs/XProfileCandidateItem"}}}},"XProfileCandidatesPresented":{"type":"object","additionalProperties":false,"required":["kind","version","requestId","acceptedCount"],"description":"Received for in-memory selection only. Does not claim the selection UI is on screen, and does not save or process items.","properties":{"kind":{"const":"profileCandidatesPresented"},"version":{"type":"integer","const":1},"requestId":{"type":"string","minLength":1,"maxLength":128},"acceptedCount":{"type":"integer","minimum":1,"maximum":100}}}}};
const schema39 = {"type":"object","additionalProperties":false,"required":["kind","version","requestId","acceptedCount"],"description":"Received for in-memory selection only. Does not claim the selection UI is on screen, and does not save or process items.","properties":{"kind":{"const":"profileCandidatesPresented"},"version":{"type":"integer","const":1},"requestId":{"type":"string","minLength":1,"maxLength":128},"acceptedCount":{"type":"integer","minimum":1,"maximum":100}}};
const schema32 = {"type":"object","additionalProperties":false,"required":["kind","version","requestId","profileURL","authorID","items"],"properties":{"kind":{"const":"xProfileCandidates"},"version":{"type":"integer","const":1},"requestId":{"type":"string","minLength":1,"maxLength":128},"profileURL":{"$ref":"#/$defs/httpsXProfileURL"},"authorID":{"$ref":"#/$defs/handle"},"profileName":{"type":"string","maxLength":80},"profileAvatarURL":{"$ref":"#/$defs/httpsTwimgProfileImageURL"},"items":{"type":"array","minItems":1,"maxItems":100,"items":{"$ref":"#/$defs/XProfileCandidateItem"}}}};
const schema33 = {"type":"string","maxLength":128,"pattern":"^https://(www\\.)?(x\\.com|twitter\\.com)/[A-Za-z0-9_]{1,15}$"};
const schema34 = {"type":"string","pattern":"^[A-Za-z0-9_]{1,15}$","not":{"enum":["home","explore","search","i","settings","login","logout","intent","signup","notifications","messages","compose","tos","privacy"]}};
const schema35 = {"type":"string","minLength":40,"maxLength":2048,"pattern":"^https://([A-Za-z0-9-]+\\.)?twimg\\.com/profile_images/"};
const func1 = (value) => [...value].length;
const pattern4 = new RegExp("^https://(www\\.)?(x\\.com|twitter\\.com)/[A-Za-z0-9_]{1,15}$", "u");
const pattern5 = new RegExp("^[A-Za-z0-9_]{1,15}$", "u");
const pattern6 = new RegExp("^https://([A-Za-z0-9-]+\\.)?twimg\\.com/profile_images/", "u");
const schema36 = {"type":"object","additionalProperties":false,"required":["id","url"],"properties":{"id":{"$ref":"#/$defs/tweetID"},"url":{"$ref":"#/$defs/httpsXStatusURL"},"previewText":{"type":"string","maxLength":200},"publishedText":{"type":"string","maxLength":40}}};
const schema37 = {"type":"string","pattern":"^[0-9]{8,25}$"};
const schema38 = {"type":"string","maxLength":256,"pattern":"^https://(www\\.)?(x\\.com|twitter\\.com)/[A-Za-z0-9_]{1,15}/status/[0-9]{8,25}$"};
const pattern7 = new RegExp("^[0-9]{8,25}$", "u");
const pattern8 = new RegExp("^https://(www\\.)?(x\\.com|twitter\\.com)/[A-Za-z0-9_]{1,15}/status/[0-9]{8,25}$", "u");

function validate22(data, {instancePath="", parentData, parentDataProperty, rootData=data, dynamicAnchors={}}={}){
let vErrors = null;
let errors = 0;
const evaluated0 = validate22.evaluated;
if(evaluated0.dynamicProps){
evaluated0.props = undefined;
}
if(evaluated0.dynamicItems){
evaluated0.items = undefined;
}
if(data && typeof data == "object" && !Array.isArray(data)){
if(data.id === undefined){
const err0 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "id"},message:"must have required property '"+"id"+"'"};
if(vErrors === null){
vErrors = [err0];
}
else {
vErrors.push(err0);
}
errors++;
}
if(data.url === undefined){
const err1 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "url"},message:"must have required property '"+"url"+"'"};
if(vErrors === null){
vErrors = [err1];
}
else {
vErrors.push(err1);
}
errors++;
}
for(const key0 in data){
if(!((((key0 === "id") || (key0 === "url")) || (key0 === "previewText")) || (key0 === "publishedText"))){
const err2 = {instancePath,schemaPath:"#/additionalProperties",keyword:"additionalProperties",params:{additionalProperty: key0},message:"must NOT have additional properties"};
if(vErrors === null){
vErrors = [err2];
}
else {
vErrors.push(err2);
}
errors++;
}
}
if(data.id !== undefined){
let data0 = data.id;
if(typeof data0 === "string"){
if(!pattern7.test(data0)){
const err3 = {instancePath:instancePath+"/id",schemaPath:"#/$defs/tweetID/pattern",keyword:"pattern",params:{pattern: "^[0-9]{8,25}$"},message:"must match pattern \""+"^[0-9]{8,25}$"+"\""};
if(vErrors === null){
vErrors = [err3];
}
else {
vErrors.push(err3);
}
errors++;
}
}
else {
const err4 = {instancePath:instancePath+"/id",schemaPath:"#/$defs/tweetID/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err4];
}
else {
vErrors.push(err4);
}
errors++;
}
}
if(data.url !== undefined){
let data1 = data.url;
if(typeof data1 === "string"){
if(func1(data1) > 256){
const err5 = {instancePath:instancePath+"/url",schemaPath:"#/$defs/httpsXStatusURL/maxLength",keyword:"maxLength",params:{limit: 256},message:"must NOT have more than 256 characters"};
if(vErrors === null){
vErrors = [err5];
}
else {
vErrors.push(err5);
}
errors++;
}
if(!pattern8.test(data1)){
const err6 = {instancePath:instancePath+"/url",schemaPath:"#/$defs/httpsXStatusURL/pattern",keyword:"pattern",params:{pattern: "^https://(www\\.)?(x\\.com|twitter\\.com)/[A-Za-z0-9_]{1,15}/status/[0-9]{8,25}$"},message:"must match pattern \""+"^https://(www\\.)?(x\\.com|twitter\\.com)/[A-Za-z0-9_]{1,15}/status/[0-9]{8,25}$"+"\""};
if(vErrors === null){
vErrors = [err6];
}
else {
vErrors.push(err6);
}
errors++;
}
}
else {
const err7 = {instancePath:instancePath+"/url",schemaPath:"#/$defs/httpsXStatusURL/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err7];
}
else {
vErrors.push(err7);
}
errors++;
}
}
if(data.previewText !== undefined){
let data2 = data.previewText;
if(typeof data2 === "string"){
if(func1(data2) > 200){
const err8 = {instancePath:instancePath+"/previewText",schemaPath:"#/properties/previewText/maxLength",keyword:"maxLength",params:{limit: 200},message:"must NOT have more than 200 characters"};
if(vErrors === null){
vErrors = [err8];
}
else {
vErrors.push(err8);
}
errors++;
}
}
else {
const err9 = {instancePath:instancePath+"/previewText",schemaPath:"#/properties/previewText/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err9];
}
else {
vErrors.push(err9);
}
errors++;
}
}
if(data.publishedText !== undefined){
let data3 = data.publishedText;
if(typeof data3 === "string"){
if(func1(data3) > 40){
const err10 = {instancePath:instancePath+"/publishedText",schemaPath:"#/properties/publishedText/maxLength",keyword:"maxLength",params:{limit: 40},message:"must NOT have more than 40 characters"};
if(vErrors === null){
vErrors = [err10];
}
else {
vErrors.push(err10);
}
errors++;
}
}
else {
const err11 = {instancePath:instancePath+"/publishedText",schemaPath:"#/properties/publishedText/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err11];
}
else {
vErrors.push(err11);
}
errors++;
}
}
}
else {
const err12 = {instancePath,schemaPath:"#/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err12];
}
else {
vErrors.push(err12);
}
errors++;
}
validate22.errors = vErrors;
return errors === 0;
}
validate22.evaluated = {"props":true,"dynamicProps":false,"dynamicItems":false};


function validate21(data, {instancePath="", parentData, parentDataProperty, rootData=data, dynamicAnchors={}}={}){
let vErrors = null;
let errors = 0;
const evaluated0 = validate21.evaluated;
if(evaluated0.dynamicProps){
evaluated0.props = undefined;
}
if(evaluated0.dynamicItems){
evaluated0.items = undefined;
}
if(data && typeof data == "object" && !Array.isArray(data)){
if(data.kind === undefined){
const err0 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "kind"},message:"must have required property '"+"kind"+"'"};
if(vErrors === null){
vErrors = [err0];
}
else {
vErrors.push(err0);
}
errors++;
}
if(data.version === undefined){
const err1 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "version"},message:"must have required property '"+"version"+"'"};
if(vErrors === null){
vErrors = [err1];
}
else {
vErrors.push(err1);
}
errors++;
}
if(data.requestId === undefined){
const err2 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "requestId"},message:"must have required property '"+"requestId"+"'"};
if(vErrors === null){
vErrors = [err2];
}
else {
vErrors.push(err2);
}
errors++;
}
if(data.profileURL === undefined){
const err3 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "profileURL"},message:"must have required property '"+"profileURL"+"'"};
if(vErrors === null){
vErrors = [err3];
}
else {
vErrors.push(err3);
}
errors++;
}
if(data.authorID === undefined){
const err4 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "authorID"},message:"must have required property '"+"authorID"+"'"};
if(vErrors === null){
vErrors = [err4];
}
else {
vErrors.push(err4);
}
errors++;
}
if(data.items === undefined){
const err5 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "items"},message:"must have required property '"+"items"+"'"};
if(vErrors === null){
vErrors = [err5];
}
else {
vErrors.push(err5);
}
errors++;
}
for(const key0 in data){
if(!((((((((key0 === "kind") || (key0 === "version")) || (key0 === "requestId")) || (key0 === "profileURL")) || (key0 === "authorID")) || (key0 === "profileName")) || (key0 === "profileAvatarURL")) || (key0 === "items"))){
const err6 = {instancePath,schemaPath:"#/additionalProperties",keyword:"additionalProperties",params:{additionalProperty: key0},message:"must NOT have additional properties"};
if(vErrors === null){
vErrors = [err6];
}
else {
vErrors.push(err6);
}
errors++;
}
}
if(data.kind !== undefined){
if("xProfileCandidates" !== data.kind){
const err7 = {instancePath:instancePath+"/kind",schemaPath:"#/properties/kind/const",keyword:"const",params:{allowedValue: "xProfileCandidates"},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err7];
}
else {
vErrors.push(err7);
}
errors++;
}
}
if(data.version !== undefined){
let data1 = data.version;
if(!((typeof data1 == "number") && (!(data1 % 1) && !isNaN(data1)))){
const err8 = {instancePath:instancePath+"/version",schemaPath:"#/properties/version/type",keyword:"type",params:{type: "integer"},message:"must be integer"};
if(vErrors === null){
vErrors = [err8];
}
else {
vErrors.push(err8);
}
errors++;
}
if(1 !== data1){
const err9 = {instancePath:instancePath+"/version",schemaPath:"#/properties/version/const",keyword:"const",params:{allowedValue: 1},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err9];
}
else {
vErrors.push(err9);
}
errors++;
}
}
if(data.requestId !== undefined){
let data2 = data.requestId;
if(typeof data2 === "string"){
if(func1(data2) > 128){
const err10 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/maxLength",keyword:"maxLength",params:{limit: 128},message:"must NOT have more than 128 characters"};
if(vErrors === null){
vErrors = [err10];
}
else {
vErrors.push(err10);
}
errors++;
}
if(func1(data2) < 1){
const err11 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err11];
}
else {
vErrors.push(err11);
}
errors++;
}
}
else {
const err12 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err12];
}
else {
vErrors.push(err12);
}
errors++;
}
}
if(data.profileURL !== undefined){
let data3 = data.profileURL;
if(typeof data3 === "string"){
if(func1(data3) > 128){
const err13 = {instancePath:instancePath+"/profileURL",schemaPath:"#/$defs/httpsXProfileURL/maxLength",keyword:"maxLength",params:{limit: 128},message:"must NOT have more than 128 characters"};
if(vErrors === null){
vErrors = [err13];
}
else {
vErrors.push(err13);
}
errors++;
}
if(!pattern4.test(data3)){
const err14 = {instancePath:instancePath+"/profileURL",schemaPath:"#/$defs/httpsXProfileURL/pattern",keyword:"pattern",params:{pattern: "^https://(www\\.)?(x\\.com|twitter\\.com)/[A-Za-z0-9_]{1,15}$"},message:"must match pattern \""+"^https://(www\\.)?(x\\.com|twitter\\.com)/[A-Za-z0-9_]{1,15}$"+"\""};
if(vErrors === null){
vErrors = [err14];
}
else {
vErrors.push(err14);
}
errors++;
}
}
else {
const err15 = {instancePath:instancePath+"/profileURL",schemaPath:"#/$defs/httpsXProfileURL/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err15];
}
else {
vErrors.push(err15);
}
errors++;
}
}
if(data.authorID !== undefined){
let data4 = data.authorID;
const _errs13 = errors;
const _errs14 = errors;
if(!((((((((((((((data4 === "home") || (data4 === "explore")) || (data4 === "search")) || (data4 === "i")) || (data4 === "settings")) || (data4 === "login")) || (data4 === "logout")) || (data4 === "intent")) || (data4 === "signup")) || (data4 === "notifications")) || (data4 === "messages")) || (data4 === "compose")) || (data4 === "tos")) || (data4 === "privacy"))){
const err16 = {};
if(vErrors === null){
vErrors = [err16];
}
else {
vErrors.push(err16);
}
errors++;
}
var valid3 = _errs14 === errors;
if(valid3){
const err17 = {instancePath:instancePath+"/authorID",schemaPath:"#/$defs/handle/not",keyword:"not",params:{},message:"must NOT be valid"};
if(vErrors === null){
vErrors = [err17];
}
else {
vErrors.push(err17);
}
errors++;
}
else {
errors = _errs13;
if(vErrors !== null){
if(_errs13){
vErrors.length = _errs13;
}
else {
vErrors = null;
}
}
}
if(typeof data4 === "string"){
if(!pattern5.test(data4)){
const err18 = {instancePath:instancePath+"/authorID",schemaPath:"#/$defs/handle/pattern",keyword:"pattern",params:{pattern: "^[A-Za-z0-9_]{1,15}$"},message:"must match pattern \""+"^[A-Za-z0-9_]{1,15}$"+"\""};
if(vErrors === null){
vErrors = [err18];
}
else {
vErrors.push(err18);
}
errors++;
}
}
else {
const err19 = {instancePath:instancePath+"/authorID",schemaPath:"#/$defs/handle/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err19];
}
else {
vErrors.push(err19);
}
errors++;
}
}
if(data.profileName !== undefined){
let data5 = data.profileName;
if(typeof data5 === "string"){
if(func1(data5) > 80){
const err20 = {instancePath:instancePath+"/profileName",schemaPath:"#/properties/profileName/maxLength",keyword:"maxLength",params:{limit: 80},message:"must NOT have more than 80 characters"};
if(vErrors === null){
vErrors = [err20];
}
else {
vErrors.push(err20);
}
errors++;
}
}
else {
const err21 = {instancePath:instancePath+"/profileName",schemaPath:"#/properties/profileName/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err21];
}
else {
vErrors.push(err21);
}
errors++;
}
}
if(data.profileAvatarURL !== undefined){
let data6 = data.profileAvatarURL;
if(typeof data6 === "string"){
if(func1(data6) > 2048){
const err22 = {instancePath:instancePath+"/profileAvatarURL",schemaPath:"#/$defs/httpsTwimgProfileImageURL/maxLength",keyword:"maxLength",params:{limit: 2048},message:"must NOT have more than 2048 characters"};
if(vErrors === null){
vErrors = [err22];
}
else {
vErrors.push(err22);
}
errors++;
}
if(func1(data6) < 40){
const err23 = {instancePath:instancePath+"/profileAvatarURL",schemaPath:"#/$defs/httpsTwimgProfileImageURL/minLength",keyword:"minLength",params:{limit: 40},message:"must NOT have fewer than 40 characters"};
if(vErrors === null){
vErrors = [err23];
}
else {
vErrors.push(err23);
}
errors++;
}
if(!pattern6.test(data6)){
const err24 = {instancePath:instancePath+"/profileAvatarURL",schemaPath:"#/$defs/httpsTwimgProfileImageURL/pattern",keyword:"pattern",params:{pattern: "^https://([A-Za-z0-9-]+\\.)?twimg\\.com/profile_images/"},message:"must match pattern \""+"^https://([A-Za-z0-9-]+\\.)?twimg\\.com/profile_images/"+"\""};
if(vErrors === null){
vErrors = [err24];
}
else {
vErrors.push(err24);
}
errors++;
}
}
else {
const err25 = {instancePath:instancePath+"/profileAvatarURL",schemaPath:"#/$defs/httpsTwimgProfileImageURL/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err25];
}
else {
vErrors.push(err25);
}
errors++;
}
}
if(data.items !== undefined){
let data7 = data.items;
if(Array.isArray(data7)){
if(data7.length > 100){
const err26 = {instancePath:instancePath+"/items",schemaPath:"#/properties/items/maxItems",keyword:"maxItems",params:{limit: 100},message:"must NOT have more than 100 items"};
if(vErrors === null){
vErrors = [err26];
}
else {
vErrors.push(err26);
}
errors++;
}
if(data7.length < 1){
const err27 = {instancePath:instancePath+"/items",schemaPath:"#/properties/items/minItems",keyword:"minItems",params:{limit: 1},message:"must NOT have fewer than 1 items"};
if(vErrors === null){
vErrors = [err27];
}
else {
vErrors.push(err27);
}
errors++;
}
const len0 = data7.length;
for(let i0=0; i0<len0; i0++){
if(!(validate22(data7[i0], {instancePath:instancePath+"/items/" + i0,parentData:data7,parentDataProperty:i0,rootData,dynamicAnchors}))){
vErrors = vErrors === null ? validate22.errors : vErrors.concat(validate22.errors);
errors = vErrors.length;
}
}
}
else {
const err28 = {instancePath:instancePath+"/items",schemaPath:"#/properties/items/type",keyword:"type",params:{type: "array"},message:"must be array"};
if(vErrors === null){
vErrors = [err28];
}
else {
vErrors.push(err28);
}
errors++;
}
}
}
else {
const err29 = {instancePath,schemaPath:"#/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err29];
}
else {
vErrors.push(err29);
}
errors++;
}
validate21.errors = vErrors;
return errors === 0;
}
validate21.evaluated = {"props":true,"dynamicProps":false,"dynamicItems":false};


function validate20(data, {instancePath="", parentData, parentDataProperty, rootData=data, dynamicAnchors={}}={}){
/*# sourceURL="https://syc.local/linkdigest/x-profile-candidates-v1.schema.json" */;
let vErrors = null;
let errors = 0;
const evaluated0 = validate20.evaluated;
if(evaluated0.dynamicProps){
evaluated0.props = undefined;
}
if(evaluated0.dynamicItems){
evaluated0.items = undefined;
}
const _errs0 = errors;
let valid0 = false;
let passing0 = null;
const _errs1 = errors;
if(!(validate21(data, {instancePath,parentData,parentDataProperty,rootData,dynamicAnchors}))){
vErrors = vErrors === null ? validate21.errors : vErrors.concat(validate21.errors);
errors = vErrors.length;
}
var _valid0 = _errs1 === errors;
if(_valid0){
valid0 = true;
passing0 = 0;
var props0 = true;
}
const _errs2 = errors;
if(data && typeof data == "object" && !Array.isArray(data)){
if(data.kind === undefined){
const err0 = {instancePath,schemaPath:"#/$defs/XProfileCandidatesPresented/required",keyword:"required",params:{missingProperty: "kind"},message:"must have required property '"+"kind"+"'"};
if(vErrors === null){
vErrors = [err0];
}
else {
vErrors.push(err0);
}
errors++;
}
if(data.version === undefined){
const err1 = {instancePath,schemaPath:"#/$defs/XProfileCandidatesPresented/required",keyword:"required",params:{missingProperty: "version"},message:"must have required property '"+"version"+"'"};
if(vErrors === null){
vErrors = [err1];
}
else {
vErrors.push(err1);
}
errors++;
}
if(data.requestId === undefined){
const err2 = {instancePath,schemaPath:"#/$defs/XProfileCandidatesPresented/required",keyword:"required",params:{missingProperty: "requestId"},message:"must have required property '"+"requestId"+"'"};
if(vErrors === null){
vErrors = [err2];
}
else {
vErrors.push(err2);
}
errors++;
}
if(data.acceptedCount === undefined){
const err3 = {instancePath,schemaPath:"#/$defs/XProfileCandidatesPresented/required",keyword:"required",params:{missingProperty: "acceptedCount"},message:"must have required property '"+"acceptedCount"+"'"};
if(vErrors === null){
vErrors = [err3];
}
else {
vErrors.push(err3);
}
errors++;
}
for(const key0 in data){
if(!((((key0 === "kind") || (key0 === "version")) || (key0 === "requestId")) || (key0 === "acceptedCount"))){
const err4 = {instancePath,schemaPath:"#/$defs/XProfileCandidatesPresented/additionalProperties",keyword:"additionalProperties",params:{additionalProperty: key0},message:"must NOT have additional properties"};
if(vErrors === null){
vErrors = [err4];
}
else {
vErrors.push(err4);
}
errors++;
}
}
if(data.kind !== undefined){
if("profileCandidatesPresented" !== data.kind){
const err5 = {instancePath:instancePath+"/kind",schemaPath:"#/$defs/XProfileCandidatesPresented/properties/kind/const",keyword:"const",params:{allowedValue: "profileCandidatesPresented"},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err5];
}
else {
vErrors.push(err5);
}
errors++;
}
}
if(data.version !== undefined){
let data1 = data.version;
if(!((typeof data1 == "number") && (!(data1 % 1) && !isNaN(data1)))){
const err6 = {instancePath:instancePath+"/version",schemaPath:"#/$defs/XProfileCandidatesPresented/properties/version/type",keyword:"type",params:{type: "integer"},message:"must be integer"};
if(vErrors === null){
vErrors = [err6];
}
else {
vErrors.push(err6);
}
errors++;
}
if(1 !== data1){
const err7 = {instancePath:instancePath+"/version",schemaPath:"#/$defs/XProfileCandidatesPresented/properties/version/const",keyword:"const",params:{allowedValue: 1},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err7];
}
else {
vErrors.push(err7);
}
errors++;
}
}
if(data.requestId !== undefined){
let data2 = data.requestId;
if(typeof data2 === "string"){
if(func1(data2) > 128){
const err8 = {instancePath:instancePath+"/requestId",schemaPath:"#/$defs/XProfileCandidatesPresented/properties/requestId/maxLength",keyword:"maxLength",params:{limit: 128},message:"must NOT have more than 128 characters"};
if(vErrors === null){
vErrors = [err8];
}
else {
vErrors.push(err8);
}
errors++;
}
if(func1(data2) < 1){
const err9 = {instancePath:instancePath+"/requestId",schemaPath:"#/$defs/XProfileCandidatesPresented/properties/requestId/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err9];
}
else {
vErrors.push(err9);
}
errors++;
}
}
else {
const err10 = {instancePath:instancePath+"/requestId",schemaPath:"#/$defs/XProfileCandidatesPresented/properties/requestId/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err10];
}
else {
vErrors.push(err10);
}
errors++;
}
}
if(data.acceptedCount !== undefined){
let data3 = data.acceptedCount;
if(!((typeof data3 == "number") && (!(data3 % 1) && !isNaN(data3)))){
const err11 = {instancePath:instancePath+"/acceptedCount",schemaPath:"#/$defs/XProfileCandidatesPresented/properties/acceptedCount/type",keyword:"type",params:{type: "integer"},message:"must be integer"};
if(vErrors === null){
vErrors = [err11];
}
else {
vErrors.push(err11);
}
errors++;
}
if(typeof data3 == "number"){
if(data3 > 100 || isNaN(data3)){
const err12 = {instancePath:instancePath+"/acceptedCount",schemaPath:"#/$defs/XProfileCandidatesPresented/properties/acceptedCount/maximum",keyword:"maximum",params:{comparison: "<=", limit: 100},message:"must be <= 100"};
if(vErrors === null){
vErrors = [err12];
}
else {
vErrors.push(err12);
}
errors++;
}
if(data3 < 1 || isNaN(data3)){
const err13 = {instancePath:instancePath+"/acceptedCount",schemaPath:"#/$defs/XProfileCandidatesPresented/properties/acceptedCount/minimum",keyword:"minimum",params:{comparison: ">=", limit: 1},message:"must be >= 1"};
if(vErrors === null){
vErrors = [err13];
}
else {
vErrors.push(err13);
}
errors++;
}
}
}
}
else {
const err14 = {instancePath,schemaPath:"#/$defs/XProfileCandidatesPresented/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err14];
}
else {
vErrors.push(err14);
}
errors++;
}
var _valid0 = _errs2 === errors;
if(_valid0 && valid0){
valid0 = false;
passing0 = [passing0, 1];
}
else {
if(_valid0){
valid0 = true;
passing0 = 1;
if(props0 !== true){
props0 = true;
}
}
}
if(!valid0){
const err15 = {instancePath,schemaPath:"#/oneOf",keyword:"oneOf",params:{passingSchemas: passing0},message:"must match exactly one schema in oneOf"};
if(vErrors === null){
vErrors = [err15];
}
else {
vErrors.push(err15);
}
errors++;
}
else {
errors = _errs0;
if(vErrors !== null){
if(_errs0){
vErrors.length = _errs0;
}
else {
vErrors = null;
}
}
}
validate20.errors = vErrors;
evaluated0.props = props0;
return errors === 0;
}
validate20.evaluated = {"dynamicProps":true,"dynamicItems":false};

