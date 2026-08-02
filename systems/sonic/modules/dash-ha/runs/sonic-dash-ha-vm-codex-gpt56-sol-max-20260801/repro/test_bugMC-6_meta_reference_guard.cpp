// MC-6 downstream safeguard reproduction.
//
// Compile this as a sairedis unittest/meta translation unit. It uses the real
// Meta implementation and MetaTestSaiInterface; no product validation is
// mocked or disabled.

#include "Meta.h"
#include "MetaTestSaiInterface.h"

#include <gtest/gtest.h>

#include <iostream>
#include <memory>

using namespace saimeta;

static sai_object_id_t mc6_create_switch(Meta &meta)
{
    sai_object_id_t switch_id = SAI_NULL_OBJECT_ID;
    sai_attribute_t attr = {};
    attr.id = SAI_SWITCH_ATTR_INIT_SWITCH;
    attr.value.booldata = true;

    EXPECT_EQ(
            SAI_STATUS_SUCCESS,
            meta.create(SAI_OBJECT_TYPE_SWITCH, &switch_id, SAI_NULL_OBJECT_ID, 1, &attr));
    return switch_id;
}

TEST(MetaDashHaDependency, HaScopeBlocksHaSetRemoval)
{
    Meta meta(std::make_shared<MetaTestSaiInterface>());

    const auto ha_set_type = static_cast<sai_object_type_t>(SAI_OBJECT_TYPE_HA_SET);
    const auto ha_scope_type = static_cast<sai_object_type_t>(SAI_OBJECT_TYPE_HA_SCOPE);

    const sai_object_id_t switch_id = mc6_create_switch(meta);
    sai_object_id_t ha_set_id = SAI_NULL_OBJECT_ID;
    sai_object_id_t ha_scope_id = SAI_NULL_OBJECT_ID;

    ASSERT_EQ(
            SAI_STATUS_SUCCESS,
            meta.create(ha_set_type, &ha_set_id, switch_id, 0, nullptr));

    sai_attribute_t scope_attr = {};
    scope_attr.id = SAI_HA_SCOPE_ATTR_HA_SET_ID;
    scope_attr.value.oid = ha_set_id;
    ASSERT_EQ(
            SAI_STATUS_SUCCESS,
            meta.create(ha_scope_type, &ha_scope_id, switch_id, 1, &scope_attr));

    const int parent_refcount = meta.getObjectReferenceCount(ha_set_id);
    EXPECT_EQ(1, parent_refcount);
    const sai_status_t parent_remove_status = meta.remove(ha_set_type, ha_set_id);
    std::cout << "MC-6 MASK: HA_SET remove while HA_SCOPE exists returned "
              << "SAI_STATUS_OBJECT_IN_USE (" << parent_remove_status
              << "), parent refcount=" << parent_refcount << std::endl;
    EXPECT_EQ(SAI_STATUS_OBJECT_IN_USE, parent_remove_status);

    EXPECT_EQ(SAI_STATUS_SUCCESS, meta.remove(ha_scope_type, ha_scope_id));
    EXPECT_EQ(0, meta.getObjectReferenceCount(ha_set_id));
    EXPECT_EQ(SAI_STATUS_SUCCESS, meta.remove(ha_set_type, ha_set_id));
}
